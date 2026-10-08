import AppKit
import CoreGraphics
import Foundation
import Hummingbird
import TetherCore

/// Outbound item queued for one WebSocket client.
enum Outgoing {
    case text(String)
    case video(ByteBuffer)
    case audio(ByteBuffer)
}

/// One connected viewer. Video is dropped (and a keyframe requested) when the
/// client falls behind, so latency stays low on slow links instead of piling up.
final class ClientConnection {
    let id = UUID()
    let login: String
    let device: String
    let connectedAt = Date()
    let continuation: AsyncStream<Outgoing>.Continuation
    var codecs: Set<VideoCodec> = [.h264]
    var lastStats = LinkStats(rttMs: 0, decodeQueue: 0, droppedFrames: 0)
    var audioFormat: AudioFormat?   // nil = sound off
    var screen: ScreenInfo?         // the device's screen, for the resolution cap
    var observe = false             // view only: control messages are ignored
    var lastInput = Date()          // for "idle 12 min" in the menu-bar panel
    private let lock = NSLock()
    private var inFlightVideo = 0
    private var waitingForKeyframe = true
    private var dropped = 0

    static let maxInFlight = 3

    init(login: String, device: String, continuation: AsyncStream<Outgoing>.Continuation) {
        self.login = login
        self.device = device
        self.continuation = continuation
    }

    func send(text: String) { continuation.yield(.text(text)) }

    /// Returns true if the client needs a fresh keyframe.
    func offerVideo(_ buffer: ByteBuffer, isKeyframe: Bool, config: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if waitingForKeyframe && !isKeyframe { return false }
        if inFlightVideo >= Self.maxInFlight {
            waitingForKeyframe = true
            dropped += 1
            return true
        }
        if isKeyframe {
            waitingForKeyframe = false
            if let config { continuation.yield(.text(config)) }
        }
        inFlightVideo += 1
        continuation.yield(.video(buffer))
        return false
    }

    func videoWritten() {
        lock.lock(); inFlightVideo -= 1; lock.unlock()
    }

    func markNeedsKeyframe() {
        lock.lock(); waitingForKeyframe = true; lock.unlock()
    }

    /// Frames dropped since the last call.
    func takeDropped() -> Int {
        lock.lock(); defer { dropped = 0; lock.unlock() }
        return dropped
    }
}

/// Owns the capture pipeline, input injection and all connected clients.
/// All mutable state lives on `queue`.
final class Hub {
    static let shared = Hub()

    let queue = DispatchQueue(label: "tether.hub", qos: .userInteractive)
    private(set) var clients: [UUID: ClientConnection] = [:]
    var onClientsChanged: (([ClientConnection]) -> Void)?

    private let streamer = ScreenStreamer()
    private let input = InputInjector()
    private let clipboard = ClipboardSync()
    private let power = PowerManager()
    private let cursor = CursorWatcher()

    /// nil = Auto (adaptive); otherwise a fixed preset.
    private var preset: QualityPreset?
    private var adaptive = AdaptiveController()
    private var displayID: CGDirectDisplayID = CGMainDisplayID()
    private var codec: VideoCodec = .h264
    private var configMessage: String?
    private var lastDescription: Data?
    private var captureTask: Task<Void, Never>?
    private var cursorTimer: DispatchSourceTimer?
    private var statsTimer: DispatchSourceTimer?
    private var lastCursor: CGPoint?
    private var macState: [String: Bool] = [:]
    private let fit = FitDisplay()
    /// Curtain windows to leave out of the stream (set from the main thread via Curtain.onChange).
    private var curtainWindowIDs: [CGWindowID] = []
    /// Failed capture starts in a row (e.g. while the display sleeps); retried every 2 seconds.
    private var captureFailures = 0
    private var captureProblem: CaptureProblem.Reason?

    static func problemMessage(_ r: CaptureProblem.Reason) -> String {
        jsonMessage("error", ["msg": r.message, "kind": r.kind, "title": r.title])
    }
    /// Single-window mode: the window, its current frame, and the frame to restore after "Fit".
    private var windowTarget: (info: WindowList.Info, rect: CGRect, restore: CGRect?)?
    private var windowTimer: DispatchSourceTimer?
    /// What the stream shows, in global points (the display, or the window in window mode).
    private var captureBounds: CGRect { windowTarget?.rect ?? CGDisplayBounds(displayID) }
    var keepAwake: Bool { queue.sync { power.held } }
    private var displayBeforeFit: CGDirectDisplayID?

    private init() {
        streamer.onFrame = { [weak self] out in self?.queue.async { self?.broadcast(out) } }
        streamer.onStopped = { [weak self] error in
            self?.queue.async {
                self?.broadcastText(jsonMessage("error", ["msg": "Capture stopped: \(error.localizedDescription)"]))
                self?.restartCapture()
            }
        }
        clipboard.onChange = { [weak self] text, html in
            var fields: [String: Any] = ["s": text]
            if let html { fields["html"] = html }
            self?.queue.async { self?.broadcastText(jsonMessage("clip", fields)) }
        }
        clipboard.onImage = { [weak self] id, w, h in
            self?.queue.async { self?.broadcastText(jsonMessage("clip", ["kind": "image", "id": id, "w": w, "h": h])) }
        }
        streamer.audioEncoder.onFrame = { [weak self] format, data in
            let frame = AudioFrameHeader.encode(format: format, timestampMicros: UInt64(Date().timeIntervalSince1970 * 1_000_000), payload: data)
            self?.queue.async {
                guard let self else { return }
                let buffer = ByteBuffer(bytes: frame)
                for c in self.clients.values where c.audioFormat == format { c.continuation.yield(.audio(buffer)) }
            }
        }
        Curtain.shared.onChange = { [weak self] on, ids in
            self?.queue.async {
                guard let self else { return }
                self.curtainWindowIDs = ids
                if !self.clients.isEmpty { self.restartCapture() }
                self.broadcastText(jsonMessage("curtain", ["on": on]))
                self.notifyClientsChanged()
            }
        }
        cursor.onChange = { [weak self] shape in
            self?.queue.async { guard let self else { return }; self.broadcastText(Self.cursorShapeMessage(shape, bounds: self.captureBounds)) }
        }
    }

    // MARK: Clients

    func add(login: String, device: String, continuation: AsyncStream<Outgoing>.Continuation) -> ClientConnection {
        let client = ClientConnection(login: login, device: device, continuation: continuation)
        Notifier.connected(device: device, login: login)
        queue.sync {
            clients[client.id] = client
            if clients.count == 1 { startSession() }
            notifyClientsChanged()
        }
        ActivityStore.shared.started(client)
        Task { await self.sendHello(to: client) }
        return client
    }

    func remove(_ client: ClientConnection) {
        client.continuation.finish()
        queue.sync {
            guard clients.removeValue(forKey: client.id) != nil else { return }
            input.releaseAll()
            if clients.isEmpty { endSession() } else { chooseCodec(); updateAudio() }
            notifyClientsChanged()
        }
        ActivityStore.shared.ended(client)
    }

    func disconnectAll() {
        queue.async { for c in self.clients.values { c.continuation.finish() } }
    }

    /// True when every open session for this login is view only (so uploads are refused too).
    func onlyObserving(login: String) -> Bool {
        queue.sync {
            let mine = clients.values.filter { $0.login.lowercased() == login.lowercased() }
            return !mine.isEmpty && mine.allSatisfy(\.observe)
        }
    }

    func clipboardImage(id: Int) -> Data? { clipboard.image(id: id) }
    func setClipboardImage(_ png: Data) -> Bool { clipboard.set(image: png) }

    /// Ends one viewer's session (the menu-bar panel's Disconnect button).
    func disconnect(id: UUID) {
        queue.async { self.clients[id]?.continuation.finish() }
    }

    private func notifyClientsChanged() {
        let list = Array(clients.values)
        DispatchQueue.main.async { self.onClientsChanged?(list) }
    }

    private func sendHello(to client: ClientConnection) async {
        let displays = (try? await Displays.list()) ?? []
        let current = queue.sync { displayID }
        let updated = await MainActor.run { Updater.shared.recentUpdate }
        var hello: [String: Any] = [
            "name": Host.current().localizedName ?? "Mac",
            "displays": displays.map(\.json),
            "display": current,
            "perms": Permissions.json,
            "state": Self.readMacState(),
            "fitAvailable": FitDisplay.isAvailable,
            "curtain": Curtain.shared.isOnApprox,
            "links": BuildInfo.links,
            "version": BuildInfo.version,   // the commit: what "was Tether updated?" compares
            "label": BuildInfo.label,       // for people: "6.0 (573e17e)"
        ]
        // Just updated: the web page shows what's new once.
        if let updated { hello["updated"] = ["version": updated.version, "label": BuildInfo.label, "whatsNew": updated.whatsNew] }
        client.send(text: jsonMessage("hello", hello))
        let bounds = queue.sync { captureBounds }
        if let shape = cursor.current { client.send(text: Self.cursorShapeMessage(shape, bounds: bounds)) }
        queue.async {
            client.markNeedsKeyframe()
            self.streamer.requestKeyframe()
            if self.windowTarget != nil { self.broadcastTarget() }
            // Where the pointer is right now, so the device can draw it before it next moves.
            if let p = self.input.normalizedCursor { client.send(text: jsonMessage("cursor", ["x": p.x, "y": p.y])) }
            // Joining while there's no picture: say why now, and try again (the lid may be open by now).
            if self.captureFailures > 0 {
                if let r = self.captureProblem { client.send(text: Self.problemMessage(r)) }
                self.captureFailures = min(self.captureFailures, 1)
                self.restartCapture()
            }
        }
    }

    // MARK: Session lifecycle

    private func startSession() {
        power.wake()
        power.setKeepAwake(true)
        clipboard.start()
        cursor.start()
        startTimers()
        restartCapture()
    }

    private func endSession() {
        exitWindowMode()
        stopFit()
        DispatchQueue.main.async { Curtain.shared.set(false) }
        power.setKeepAwake(false)
        clipboard.stop()
        cursor.stop()
        cursorTimer?.cancel(); cursorTimer = nil
        statsTimer?.cancel(); statsTimer = nil
        let previous = captureTask
        captureTask = Task {
            await previous?.value
            await self.streamer.stop()
        }
    }

    private var currentSettings: ScreenStreamer.Settings {
        if let preset {
            return .init(displayID: displayID, codec: codec, maxWidth: preset.maxWidth, fps: preset.fps,
                         bitrate: codec == .hevc ? preset.bitrate * 7 / 10 : preset.bitrate, audio: wantsAudio,
                         excludedWindowIDs: curtainWindowIDs, windowID: windowTarget?.info.id)
        }
        return .init(displayID: displayID, codec: codec, maxWidth: adaptive.maxWidth, fps: adaptive.fps,
                     bitrate: adaptive.bitrate, audio: wantsAudio, excludedWindowIDs: curtainWindowIDs,
                     windowID: windowTarget?.info.id)
    }

    /// Caps Auto quality at the largest connected device's screen. A device that didn't say lifts the cap.
    /// Returns true when the current resolution went down.
    private func applyDeviceCap() -> Bool {
        let macAspect = Double(CGDisplayPixelsWide(displayID)) / Double(max(1, CGDisplayPixelsHigh(displayID)))
        let caps = clients.values.map { c in
            c.screen.map { Sizing.deviceCap(w: $0.w, h: $0.h, dpr: $0.dpr, macAspect: macAspect) } ?? Int.max
        }
        guard let widest = caps.max() else { return false }
        return adaptive.setMaxLevel(AdaptiveController.level(fitting: widest)) && preset == nil
    }

    private var wantsAudio: Bool { clients.values.contains { $0.audioFormat != nil } }

    /// Applies who wants sound in which format; restarts capture only when audio turns on/off.
    private func updateAudio() {
        let formats = Set(clients.values.compactMap(\.audioFormat))
        streamer.audioEncoder.wantAAC = formats.contains(.aac)
        streamer.audioEncoder.wantPCM = formats.contains(.pcm)
        if streamer.capturingAudio != !formats.isEmpty { restartCapture() }
    }

    /// Removes the virtual display and returns to the display used before.
    private func stopFit() {
        DispatchQueue.main.sync { fit.stop() }
        if let previous = displayBeforeFit {
            displayID = previous
            displayBeforeFit = nil
        }
    }

    static func readMacState() -> [String: Bool] {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = (session?["CGSSessionScreenIsLocked"] as? Bool) ?? false
        let asleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        return ["locked": locked, "asleep": asleep, "lidClosed": lidClosed]
    }

    /// A MacBook's lid is shut (with no other display there's nothing to capture).
    static var lidClosed: Bool {
        let root = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IOPMrootDomain")
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let v = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (v as? Bool) ?? false
    }

    /// Restarts capture with current settings. Serialized via task chaining.
    private func restartCapture() {
        let previous = captureTask
        let settings = currentSettings
        input.displayID = settings.displayID
        input.captureRect = windowTarget?.rect
        configMessage = nil
        lastDescription = nil
        for c in clients.values { c.markNeedsKeyframe() }
        captureTask = Task {
            await previous?.value
            guard self.queue.sync(execute: { !self.clients.isEmpty }) else { return }
            do {
                try await self.streamer.start(settings)
                self.queue.async { self.captureFailures = 0; self.captureProblem = nil }
            } catch {
                NSLog("Tether: capture failed: \(error)")
                let state = Self.readMacState()
                let reason = CaptureProblem.reason(screenRecording: Permissions.screenRecording, lidClosed: state["lidClosed"] == true,
                                                   asleep: state["asleep"] == true, error: error.localizedDescription)
                if state["asleep"] == true { self.power.wake() }
                self.queue.async {
                    // Say why (again whenever the reason changes), then keep trying quietly: a display
                    // that wakes or a lid that opens brings the picture back by itself.
                    if self.captureFailures == 0 || reason != self.captureProblem {
                        self.captureProblem = reason
                        self.broadcastText(Self.problemMessage(reason))
                    }
                    self.captureFailures += 1
                    guard Permissions.screenRecording, self.captureFailures <= 150 else { return }
                    self.queue.asyncAfter(deadline: .now() + 2) {
                        if !self.clients.isEmpty && self.captureFailures > 0 { self.restartCapture() }
                    }
                }
            }
        }
    }

    /// HEVC only when every connected client can decode it.
    private func chooseCodec() {
        let all = clients.values.map(\.codecs)
        let wanted: VideoCodec = !all.isEmpty && all.allSatisfy { $0.contains(.hevc) } ? .hevc : .h264
        guard wanted != codec else { return }
        codec = wanted
        adaptive = AdaptiveController(startLevel: adaptive.level, bitsPerPixel: wanted == .hevc ? 0.045 : 0.07)
        _ = applyDeviceCap()
        restartCapture()
    }

    // MARK: Fan-out

    private func broadcast(_ out: VideoEncoder.Output) {
        if out.isKeyframe, let desc = out.description, desc != lastDescription {
            let codecString = streamer.codec == .hevc ? HEVC.codecString(hvcC: desc) : H264.codecString(avcC: desc)
            if let codecString {
                lastDescription = desc
                let size = streamer.size
                configMessage = jsonMessage("config", [
                    "codec": codecString, "desc": desc.base64EncodedString(), "w": size.width, "h": size.height,
                    "auto": preset == nil,
                ])
            }
        }
        let frame = VideoFrameHeader.encode(isKeyframe: out.isKeyframe, timestampMicros: out.timestampMicros, payload: out.data)
        let buffer = ByteBuffer(bytes: frame)
        var needKey = false
        for c in clients.values where c.offerVideo(buffer, isKeyframe: out.isKeyframe, config: configMessage) {
            needKey = true
        }
        if needKey { streamer.requestKeyframe() }
    }

    private func broadcastText(_ text: String) {
        for c in clients.values { c.send(text: text) }
    }

    private static func cursorShapeMessage(_ s: CursorWatcher.Shape, bounds b: CGRect) -> String {
        return jsonMessage("cursorShape", [
            "png": s.pngBase64, "w": s.widthPoints, "h": s.heightPoints, "hx": s.hotX, "hy": s.hotY,
            // Size relative to the display, so clients can scale it with the video.
            "nw": b.width > 0 ? s.widthPoints / b.width : 0, "nh": b.height > 0 ? s.heightPoints / b.height : 0,
        ])
    }

    private func startTimers() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(16))
        t.setEventHandler { [weak self] in
            guard let self, let p = self.input.normalizedCursor else { return }
            if let last = self.lastCursor, abs(last.x - p.x) < 0.0002, abs(last.y - p.y) < 0.0002 { return }
            self.lastCursor = p
            self.broadcastText(jsonMessage("cursor", ["x": p.x, "y": p.y]))
        }
        t.resume()
        cursorTimer = t

        let s = DispatchSource.makeTimerSource(queue: queue)
        s.schedule(deadline: .now() + 1, repeating: .seconds(1))
        s.setEventHandler { [weak self] in self?.adaptTick() }
        s.resume()
        statsTimer = s
    }

    /// Once a second: feed the worst client's link health to the adaptive controller.
    private func adaptTick() {
        let state = Self.readMacState()
        if state != macState {
            // The display woke up: capture may have stopped while it slept, so start it fresh.
            if macState["asleep"] == true && state["asleep"] == false { restartCapture() }
            macState = state
            broadcastText(jsonMessage("state", state))
        }
        var worst: LinkStats?
        for c in clients.values {
            var stats = c.lastStats
            stats.droppedFrames = c.takeDropped()
            let score = Double(stats.droppedFrames) * 100 + Double(stats.decodeQueue) * 20 + stats.rttMs
            let worstScore = worst.map { Double($0.droppedFrames) * 100 + Double($0.decodeQueue) * 20 + $0.rttMs } ?? -1
            if score > worstScore { worst = stats }
        }
        guard preset == nil, let worst else { return }
        if applyDeviceCap() { restartCapture() }
        let decision = adaptive.update(worst)
        if decision.resolutionChanged {
            restartCapture()
        } else if decision.bitrateChanged {
            streamer.setBitrate(decision.bitrate)
        }
        if decision.resolutionChanged || decision.bitrateChanged {
            broadcastText(jsonMessage("quality", ["auto": true, "maxWidth": decision.maxWidth, "bitrate": decision.bitrate]))
        }
    }

    // MARK: Single-window mode

    private func enterWindowMode(_ info: WindowList.Info, fit: Bool, aspect: Double, from client: ClientConnection) {
        exitWindowMode()
        if displayBeforeFit != nil { stopFit(); broadcastText(jsonMessage("fit", ["mode": "off"])) }
        DispatchQueue.main.sync { WindowList.raise(info) }   // so clicks land on it
        var restore: CGRect?
        if fit && aspect > 0 {
            let screen = CGDisplayBounds(displayID)
            let size = WindowGeometry.fitSize(window: info.frame.size, aspect: aspect, screen: screen.size)
            let origin = CGPoint(x: min(max(info.frame.minX, screen.minX), screen.maxX - size.width),
                                 y: min(max(info.frame.minY, screen.minY + 30), screen.maxY - size.height))
            let ok = DispatchQueue.main.sync { WindowList.resize(info, to: size, origin: origin) }
            if ok { restore = info.frame; Thread.sleep(forTimeInterval: 0.2) }
            else { client.send(text: jsonMessage("error", ["msg": "This window can't be resized, so it's shown at its own size."])) }
        }
        windowTarget = (info, WindowList.frame(of: info.id) ?? info.frame, restore)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.watchWindow() }
        t.resume()
        windowTimer = t
        restartCapture()
        broadcastTarget()
    }

    /// Follows the window: moved → remap input; resized → restart capture; closed → whole screen.
    private func watchWindow() {
        guard let target = windowTarget else { return }
        guard let frame = WindowList.frame(of: target.info.id) else {
            exitWindowMode(restoreFrame: false)
            restartCapture()
            broadcastText(jsonMessage("error", ["msg": "The window closed, so you're seeing the whole screen again."]))
            broadcastTarget()
            return
        }
        guard frame != target.rect else { return }
        let resized = WindowGeometry.sizeChanged(target.rect, frame)
        windowTarget?.rect = frame
        input.captureRect = frame
        if resized { restartCapture() }
    }

    private func exitWindowMode(restoreFrame: Bool = true) {
        windowTimer?.cancel()
        windowTimer = nil
        if restoreFrame, let t = windowTarget, let r = t.restore {
            let info = t.info
            DispatchQueue.main.async { WindowList.resize(info, to: r.size, origin: r.origin) }
        }
        windowTarget = nil
        input.captureRect = nil
    }

    private func broadcastTarget() {
        if let t = windowTarget {
            broadcastText(jsonMessage("target", ["window": t.info.id, "title": t.info.title, "app": t.info.app, "fit": t.restore != nil]))
        } else {
            broadcastText(jsonMessage("target", ["window": NSNull()]))
        }
    }

    // MARK: Inbound

    func handle(_ message: ClientMessage, from client: ClientConnection) {
        queue.async { self.apply(message, from: client) }
    }

    private func apply(_ message: ClientMessage, from client: ClientConnection) {
        if InputPolicy.isActivity(message) { client.lastInput = Date() }
        // View only is enforced here, not just in the browser.
        if client.observe && InputPolicy.isControl(message) { return }
        switch message {
        case let .hello(quality, display, codecs, screen):
            client.codecs = Set(codecs.isEmpty ? [.h264] : codecs)
            client.screen = screen
            var changed = applyDeviceCap()
            let newPreset = quality.flatMap(QualityPreset.init(rawValue:))
            if newPreset != preset { preset = newPreset; changed = true }
            if let d = display, d != displayID, CGDisplayIsActive(d) != 0 { displayID = d; changed = true }
            let before = codec
            chooseCodec()
            if changed && codec == before { restartCapture() }
        case let .quality(name):
            let newPreset = QualityPreset(rawValue: name)  // "auto" → nil
            if newPreset != preset { preset = newPreset; restartCapture() }
        case let .display(id):
            if id != displayID { displayID = id; restartCapture() }
            broadcastText(jsonMessage("display", ["id": id]))
            if let shape = cursor.current { broadcastText(Self.cursorShapeMessage(shape, bounds: CGDisplayBounds(id))) }
        case .keyframe:
            client.markNeedsKeyframe()
            streamer.requestKeyframe()
        case let .audio(on, format):
            client.audioFormat = on ? format : nil
            updateAudio()
        case .wake:
            power.wake()
        case let .fit(modeName, width, height):
            let mode = FitDisplay.Mode(rawValue: modeName) ?? .off
            if mode != .off && windowTarget != nil { exitWindowMode(); broadcastTarget() }   // one or the other
            if mode == .off { stopFit(); restartCapture(); broadcastText(jsonMessage("fit", ["mode": "off"])); return }
            let created: CGDirectDisplayID? = DispatchQueue.main.sync { fit.start(mode: mode, viewportWidth: width, viewportHeight: height) }
            if let id = created {
                if displayBeforeFit == nil { displayBeforeFit = displayID }
                displayID = id
                restartCapture()
                broadcastText(jsonMessage("fit", ["mode": DispatchQueue.main.sync { fit.mode.rawValue }]))
            } else {
                client.send(text: jsonMessage("error", ["msg": "Fit to device isn't available on this Mac."]))
            }
        case let .ping(id):
            client.send(text: jsonMessage("pong", ["id": id]))
        case let .stats(rtt, queueLength):
            client.lastStats.rttMs = rtt
            client.lastStats.decodeQueue = queueLength
        case let .move(x, y): input.move(x: x, y: y)
        case let .moveRelative(dx, dy): input.moveRelative(dx: dx, dy: dy)
        case let .button(index, down): input.button(index, down: down)
        case let .scroll(dx, dy): input.scroll(dx: dx, dy: dy)
        case let .key(code, down): input.key(code: code, down: down)
        case let .text(s): input.type(text: s)
        case let .setClipboard(s): clipboard.set(s)
        case .releaseAll: input.releaseAll()
        case let .observe(on):
            client.observe = on
            if on { input.releaseAll() }
            notifyClientsChanged()
        case let .curtain(on):
            DispatchQueue.main.async { Curtain.shared.set(on) }
        case .activity:
            break
        case let .action(a):
            if let key = a.mediaKey { DispatchQueue.main.async { QuickActions.media(key) } }
            else if let combo = a.combo {
                for code in combo { input.key(code: code, down: true) }
                for code in combo.reversed() { input.key(code: code, down: false) }
            } else if a == .sleepDisplay { QuickActions.sleepDisplay() }
        case let .openURL(s):
            if let url = SafeURL.validate(s) { DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
            else { client.send(text: jsonMessage("error", ["msg": "Only web links (http or https) can be opened on the Mac."])) }
        case let .openApp(path):
            guard AppCatalog.contains(path) else { return }
            DispatchQueue.main.async {
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
            }
        case .windows:
            Task {
                let list = await WindowList.list()
                client.send(text: jsonMessage("windows", ["list": WindowList.json(list)]))
            }
        case let .focusWindow(id):
            Task {
                guard let info = await WindowList.list().first(where: { $0.id == id }) else { return }
                DispatchQueue.main.async { WindowList.raise(info) }
            }
        case let .captureWindow(id, fit, aspect):
            guard let id else {
                exitWindowMode()
                restartCapture()
                broadcastTarget()
                return
            }
            Task {
                guard let info = await WindowList.list().first(where: { $0.id == id }) else {
                    client.send(text: jsonMessage("error", ["msg": "That window isn't on screen any more."]))
                    return
                }
                self.queue.async { self.enterWindowMode(info, fit: fit, aspect: aspect, from: client) }
            }
        }
    }
}
