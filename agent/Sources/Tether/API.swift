import AppKit
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import ScreenCaptureKit
import TetherCore

/// The HTTP API for programs (Claude through mcp-tether): /api/v1/… Shapes and the coordinate
/// contract are in TetherCore/APIProtocol.swift; every route is described in docs/API.md.
enum API {
    /// Screenshots per second per login; capture at full 5K size is the expensive part.
    static let screenshotsPerSecond = 4

    static let targetHeader = HTTPField.Name("X-Tether-Target")!
    static let imageSizeHeader = HTTPField.Name("X-Tether-Image-Size")!
    static let pointsHeader = HTTPField.Name("X-Tether-Points")!
    /// The calling device's name, shown on the Mac (one API client per login and device).
    static let clientHeader = HTTPField.Name("X-Tether-Client")!
    static let defaultClientName = "Claude"
    static let maxClientNameLength = 40
    /// After raising a window target, before acting on it.
    static let raiseSettleMs = 150

    /// Until the Allow Claude switch exists (P-3 S-17), the API answers only in dev mode
    /// (scripts/dev.sh), so a real install never serves it without that switch.
    static func enabled(policy: AuthPolicy) -> Bool { policy.devMode }

    static func register(on router: Router<BasicWebSocketRequestContext>, policy: AuthPolicy) {
        let api = router.group(RouterPath(String(APIVersion.prefix.dropFirst())))
        let limiter = RateLimiter(perSecond: screenshotsPerSecond)
        // Until the Allow Claude switch (S-17): Control in dev mode, so actions can be tested there.
        if enabled(policy: policy) { Hub.shared.setAPIAccess(.control) }

        api.post("actions") { request, _ -> Response in
            guard enabled(policy: policy) else { return off() }
            var req = request
            let body: ByteBuffer
            do {
                body = try await req.collectBody(upTo: APIActionRequest.maxBytes)
            } catch {
                return answer(APIError("The request is over \(APIActionRequest.maxBytes / 1024) KB."), status: .contentTooLarge)
            }
            let device = String((request.headers[clientHeader] ?? defaultClientName).prefix(maxClientNameLength))
            return await Actions.run(Data(buffer: body), login: Server.login(request), device: device)
        }

        api.get("info") { _, _ -> Response in
            guard enabled(policy: policy) else { return off() }
            return answer(await info())
        }

        api.get("windows") { _, _ -> Response in
            guard enabled(policy: policy) else { return off() }
            return answer(["windows": await windows()])
        }

        api.get("apps") { _, _ -> Response in
            guard enabled(policy: policy) else { return off() }
            let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path })
            let apps = AppCatalog.list().map { APIApp(name: $0["name"] ?? "", path: $0["path"] ?? "", running: running.contains($0["path"] ?? "")) }
            return answer(["apps": apps])
        }

        api.get("screenshot") { request, _ -> Response in
            guard enabled(policy: policy) else { return off() }
            guard limiter.allow(Server.login(request)) else {
                return answer(APIError("Too many screenshots. At most \(screenshotsPerSecond) a second."), status: .tooManyRequests)
            }
            var query: [String: String] = [:]
            for (k, v) in request.uri.queryParameters { query[String(k)] = String(v) }
            let parsed: APIScreenshotRequest
            switch APIScreenshotRequest.parse(query) {
            case .success(let r): parsed = r
            case .failure(let e): return answer(e, status: .badRequest)
            }
            switch await Screenshots.capture(parsed) {
            case .failure(let f):
                return answer(f.error, status: f.status)
            case .success(let shot):
                return Response(status: .ok, headers: [
                    .contentType: parsed.format.contentType, .cacheControl: "no-store",
                    targetHeader: parsed.target.header(resolvedDisplay: shot.display),
                    imageSizeHeader: "\(shot.size.w)x\(shot.size.h)",
                    pointsHeader: "\(Int(shot.points.minX)),\(Int(shot.points.minY)),\(Int(shot.points.width)),\(Int(shot.points.height))",
                ], body: .init(byteBuffer: ByteBuffer(bytes: shot.data)))
            }
        }
    }

    static func info() async -> APIInfo {
        APIInfo(name: Host.current().localizedName ?? "Mac", version: BuildInfo.label,
                displays: await displays(),
                permissions: .init(screenRecording: Permissions.screenRecording, accessibility: Permissions.accessibility),
                paused: AppState.shared.paused)
    }

    static func displays() async -> [APIInfo.Display] {
        let list = (try? await Displays.list()) ?? []
        return list.map { d in
            let bounds = CGDisplayBounds(d.id)
            return APIInfo.Display(id: d.id, name: d.name, main: d.id == CGMainDisplayID(), points: APIRect(bounds),
                                   pixels: APISize(w: d.pixelWidth, h: d.pixelHeight), scale: Screenshots.scale(of: d.id))
        }
    }

    static func windows() async -> [APIWindow] {
        let bounds = activeDisplays().map { (id: $0, bounds: CGDisplayBounds($0)) }
        return await WindowList.list().map { w in
            APIWindow(id: w.id, title: w.title, app: w.app, bundle: w.bundleID, pid: w.pid, frame: APIRect(w.frame),
                      display: APIGeometry.display(containing: CGPoint(x: w.frame.midX, y: w.frame.midY), in: bounds) ?? CGMainDisplayID())
        }
    }

    static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [CGMainDisplayID()] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [CGMainDisplayID()] }
        return Array(ids.prefix(Int(count)))
    }

    static func answer<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) -> Response {
        Response(status: status, headers: [.contentType: "application/json; charset=utf-8", .cacheControl: "no-store"],
                 body: .init(byteBuffer: ByteBuffer(bytes: APIJSON.encode(value))))
    }

    static func off() -> Response {
        answer(APIError("The API is off on this Mac."), status: .forbidden)
    }
}

/// Full-size or scaled PNG/JPEG screenshots of a display or one window, for the API.
/// (Thumbnails.capture is the small-JPEG-of-a-display version for the Macs picker.)
enum Screenshots {
    struct Failure: Error {
        let error: APIError
        let status: HTTPResponse.Status
        init(_ message: String, _ status: HTTPResponse.Status = .serviceUnavailable) {
            error = APIError(message); self.status = status
        }
    }

    struct Shot {
        let data: Data
        let size: APISize
        let points: CGRect
        let display: UInt32
    }

    /// Pixels per point of a display (2 on Retina).
    static func scale(of id: CGDirectDisplayID) -> Double {
        let bounds = CGDisplayBounds(id)
        guard bounds.width > 0, let mode = CGDisplayCopyDisplayMode(id) else { return 1 }
        return Double(mode.pixelWidth) / Double(bounds.width)
    }

    static func capture(_ req: APIScreenshotRequest) async -> Result<Shot, Failure> {
        guard Permissions.screenRecording else {
            return .failure(Failure("Screen Recording is off for Tether. Turn it on in System Settings → Privacy & Security."))
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            return .failure(Failure("Couldn't read the screen: \(error.localizedDescription)"))
        }
        let filter: SCContentFilter, points: CGRect, displayID: UInt32
        switch req.target {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == (id ?? CGMainDisplayID()) }) else {
                return .failure(Failure("No display with that id. See /api/v1/info.", .notFound))
            }
            let mine = content.windows.filter { $0.owningApplication?.processID == getpid() }
            filter = SCContentFilter(display: display, excludingWindows: mine)
            points = CGDisplayBounds(display.displayID)
            displayID = display.displayID
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id && $0.isOnScreen }),
                  window.owningApplication?.processID != getpid() else {
                return .failure(Failure("No window with that id on screen. See /api/v1/windows.", .notFound))
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            points = window.frame
            let ids = API.activeDisplays().map { (id: $0, bounds: CGDisplayBounds($0)) }
            displayID = APIGeometry.display(containing: CGPoint(x: points.midX, y: points.midY), in: ids) ?? CGMainDisplayID()
        }
        let size = APIGeometry.imageSize(points: points.size, scale: scale(of: displayID), requestedWidth: req.width)
        let config = SCStreamConfiguration()
        config.width = size.w
        config.height = size.h
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            return .failure(Failure("Couldn't take the screenshot: \(error.localizedDescription)"))
        }
        let rep = NSBitmapImageRep(cgImage: image)
        let data = req.format == .png
            ? rep.representation(using: .png, properties: [:])
            : rep.representation(using: .jpeg, properties: [.compressionFactor: req.quality])
        guard let data else { return .failure(Failure("Couldn't encode the screenshot.")) }
        return .success(Shot(data: data, size: APISize(w: image.width, h: image.height), points: points, display: displayID))
    }
}

/// POST /api/v1/actions: check the whole list, then run it in order through the Hub.
enum Actions {
    static func run(_ body: Data, login: String, device: String) async -> Response {
        let parsed: APIActionRequest
        switch APIActionRequest.parse(body) {
        case .success(let r): parsed = r
        case .failure(let e): return API.answer(e, status: .badRequest)
        }
        for (i, action) in parsed.actions.enumerated() {
            if case .openApp(let path) = action, !AppCatalog.contains(path) {
                return API.answer(APIError("That app isn't in /api/v1/apps.", index: i), status: .badRequest)
            }
        }
        let window: WindowList.Info?, target: CGRect
        switch parsed.target {
        case .display(let id):
            let d = id ?? CGMainDisplayID()
            guard API.activeDisplays().contains(d) else {
                return API.answer(APIError("No display with that id. See /api/v1/info."), status: .notFound)
            }
            window = nil
            target = CGDisplayBounds(d)
        case .window(let id):
            guard let info = await WindowList.list().first(where: { $0.id == id }) else {
                return API.answer(APIError("No window with that id on screen. See /api/v1/windows."), status: .notFound)
            }
            window = info
            target = WindowList.frame(of: id) ?? info.frame
        }
        let displays = API.activeDisplays().map { (id: $0, bounds: CGDisplayBounds($0)) }
        let resolve = APIGeometry.resolver(image: parsed.image ?? APISize(w: 1, h: 1), target: target, displays: displays)
        let steps: [[APIStep]]
        switch parsed.steps(resolve: resolve) {
        case .success(let s): steps = s
        case .failure(let e): return API.answer(e, status: .badRequest)
        }
        if AppState.shared.paused { return paused(index: 0) }

        let client = Hub.shared.apiClient(login: login, device: device)
        if let window, parsed.actions.contains(where: \.hasCoordinates) {
            await MainActor.run { WindowList.raise(window) }
            try? await Task.sleep(for: .milliseconds(API.raiseSettleMs))
        }
        for (i, actionSteps) in steps.enumerated() {
            if AppState.shared.paused { return paused(index: i) }
            for step in actionSteps {
                switch Hub.shared.applyAPI(step.message, from: client, display: step.display) {
                case .ok: break
                case .viewOnly:
                    return API.answer(APIError("Allow Claude is set to View only on this Mac, so input is off.", index: i), status: .forbidden)
                case .gone:
                    return API.answer(APIError("Claude was disconnected on the Mac.", index: i), status: .forbidden)
                case .notAllowed:
                    return API.answer(APIError("That action isn't allowed through the API.", index: i), status: .forbidden)
                }
                if step.pauseMs > 0 { try? await Task.sleep(for: .milliseconds(step.pauseMs)) }
            }
        }
        return API.answer(APIActionResult(done: steps.count))
    }

    private static func paused(index: Int) -> Response {
        API.answer(APIError("Remote access is paused on the Mac.", index: index), status: .serviceUnavailable)
    }
}
