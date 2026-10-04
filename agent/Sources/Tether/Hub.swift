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
    private var displayBeforeFit: CGDirectDisplayID?

    private init() {
        streamer.onFrame = { [weak self] out in self?.queue.async { self?.broadcast(out) } }
        streamer.onStopped = { [weak self] error in
            self?.queue.async {
                self?.broadcastText(jsonMessage("error", ["msg": "Capture stopped: \(error.localizedDescription)"]))
                self?.restartCapture()
            }
        }
        clipboard.onChange = { [weak self] text in
            self?.queue.async { self?.broadcastText(jsonMessage("clip", ["s": text])) }
        }
        streamer.audioEncoder.onFrame = { [weak self] format, data in
            let frame = AudioFrameHeader.encode(format: format, timestampMicros: UInt64(Date().timeIntervalSince1970 * 1_000_000), payload: data)
            self?.queue.async {
                guard let self else { return }
                let buffer = ByteBuffer(bytes: frame)
                for c in self.clients.values where c.audioFormat == format { c.continuation.yield(.audio(buffer)) }
            }
        }
        cursor.onChange = { [weak self] shape in
            self?.queue.async { self?.broadcastText(Self.cursorShapeMessage(shape, display: self?.displayID ?? 0)) }
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
    }

    func disconnectAll() {
        queue.async { for c in self.clients.values { c.continuation.finish() } }
    }

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
        client.send(text: jsonMessage("hello", [
            "name": Host.current().localizedName ?? "Mac",
            "displays": displays.map(\.json),
            "display": current,
            "perms": Permissions.json,
            "state": Self.readMacState(),
            "fitAvailable": FitDisplay.isAvailable,
        ]))
        if let shape = cursor.current { client.send(text: Self.cursorShapeMessage(shape, display: current)) }
        queue.async {
            client.markNeedsKeyframe()
            self.streamer.requestKeyframe()
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
        stopFit()
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
                         bitrate: codec == .hevc ? preset.bitrate * 7 / 10 : preset.bitrate, audio: wantsAudio)
        }
        return .init(displayID: displayID, codec: codec, maxWidth: adaptive.maxWidth, fps: adaptive.fps,
                     bitrate: adaptive.bitrate, audio: wantsAudio)
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
        return ["locked": locked, "asleep": asleep]
    }

    /// Restarts capture with current settings. Serialized via task chaining.
    private func restartCapture() {
        let previous = captureTask
        let settings = currentSettings
        input.displayID = settings.displayID
        configMessage = nil
        lastDescription = nil
        for c in clients.values { c.markNeedsKeyframe() }
        captureTask = Task {
            await previous?.value
            guard self.queue.sync(execute: { !self.clients.isEmpty }) else { return }
            do {
                try await self.streamer.start(settings)
            } catch {
                NSLog("Tether: capture failed: \(error)")
                let msg = Permissions.screenRecording
                    ? "Couldn't start screen capture: \(error.localizedDescription)"
                    : "Screen Recording permission is off for Tether on this Mac."
                self.queue.async { self.broadcastText(jsonMessage("error", ["msg": msg])) }
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

    private static func cursorShapeMessage(_ s: CursorWatcher.Shape, display: CGDirectDisplayID) -> String {
        let b = CGDisplayBounds(display)
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

    // MARK: Inbound

    func handle(_ message: ClientMessage, from client: ClientConnection) {
        queue.async { self.apply(message, from: client) }
    }

    private func apply(_ message: ClientMessage, from client: ClientConnection) {
        switch message {
        case let .hello(quality, display, codecs):
            client.codecs = Set(codecs.isEmpty ? [.h264] : codecs)
            var changed = false
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
            if let shape = cursor.current { broadcastText(Self.cursorShapeMessage(shape, display: id)) }
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
        }
    }
}
