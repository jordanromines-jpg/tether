import CoreGraphics
import Foundation

/// Request and answer shapes for the HTTP API at /api/v1 (docs/API.md), shared by the agent and
/// SelfTest. Every answer is JSON with sorted keys, except screenshots, which are PNG or JPEG.
public enum APIVersion {
    public static let current = 1
    public static let prefix = "/api/v1"
}

/// A rectangle in global screen points (top-left origin, like CGDisplayBounds and window frames).
public struct APIRect: Codable, Equatable, Sendable {
    public var x: Double, y: Double, w: Double, h: Double
    public init(_ r: CGRect) { x = Double(r.minX); y = Double(r.minY); w = Double(r.width); h = Double(r.height) }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

public struct APISize: Codable, Equatable, Sendable {
    public var w: Int, h: Int
    public init(w: Int, h: Int) { self.w = w; self.h = h }
}

/// GET /api/v1/info
public struct APIInfo: Codable, Equatable, Sendable {
    public struct Display: Codable, Equatable, Sendable {
        public var id: UInt32
        public var name: String
        public var main: Bool
        /// Where the display sits, in global points.
        public var points: APIRect
        /// Its native resolution in pixels.
        public var pixels: APISize
        /// Pixels per point (2 on a Retina display).
        public var scale: Double
        public init(id: UInt32, name: String, main: Bool, points: APIRect, pixels: APISize, scale: Double) {
            self.id = id; self.name = name; self.main = main; self.points = points; self.pixels = pixels; self.scale = scale
        }
    }

    public struct Permissions: Codable, Equatable, Sendable {
        public var screenRecording: Bool
        public var accessibility: Bool
        public init(screenRecording: Bool, accessibility: Bool) {
            self.screenRecording = screenRecording; self.accessibility = accessibility
        }
    }

    public var api: Int
    public var name: String
    /// "6.0 (573e17e)", or the short commit when there's no version number.
    public var version: String
    public var displays: [Display]
    public var permissions: Permissions
    public var paused: Bool

    public init(name: String, version: String, displays: [Display], permissions: Permissions, paused: Bool) {
        api = APIVersion.current
        self.name = name; self.version = version; self.displays = displays; self.permissions = permissions; self.paused = paused
    }
}

/// GET /api/v1/windows
public struct APIWindow: Codable, Equatable, Sendable {
    public var id: UInt32
    public var title: String
    public var app: String
    public var bundle: String
    public var pid: Int32
    /// The window's frame in global points.
    public var frame: APIRect
    /// The display its centre is on.
    public var display: UInt32
    public init(id: UInt32, title: String, app: String, bundle: String, pid: Int32, frame: APIRect, display: UInt32) {
        self.id = id; self.title = title; self.app = app; self.bundle = bundle; self.pid = pid; self.frame = frame; self.display = display
    }
}

/// GET /api/v1/apps: apps that open-app may launch, and whether each is running.
public struct APIApp: Codable, Equatable, Sendable {
    public var name: String
    public var path: String
    public var running: Bool
    public init(name: String, path: String, running: Bool) { self.name = name; self.path = path; self.running = running }
}

/// Every refusal: `{"error": "<plain reason>"}`; `index` is set when an action list stopped midway.
public struct APIError: Codable, Equatable, Sendable, Error {
    public var error: String
    public var index: Int?
    public init(_ error: String, index: Int? = nil) { self.error = error; self.index = index }
}

/// What a screenshot shows, and so what an action's coordinates are relative to.
public enum APITarget: Equatable, Sendable {
    case display(UInt32?)   // nil = the main display
    case window(UInt32)

    /// From the query parameters `display=<id>` or `window=<id>` (neither = the main display).
    public static func parse(display: String?, window: String?) -> Result<APITarget, APIError> {
        if display != nil, window != nil { return .failure(APIError("Choose a display or a window, not both.")) }
        if let window {
            guard let id = UInt32(window) else { return .failure(APIError("window must be a window id from /api/v1/windows.")) }
            return .success(.window(id))
        }
        if let display {
            guard let id = UInt32(display) else { return .failure(APIError("display must be a display id from /api/v1/info.")) }
            return .success(.display(id))
        }
        return .success(.display(nil))
    }

    /// The `X-Tether-Target` header value: "display 1" or "window 1234".
    public func header(resolvedDisplay: UInt32) -> String {
        switch self {
        case .display: return "display \(resolvedDisplay)"
        case .window(let id): return "window \(id)"
        }
    }
}

public enum APIImageFormat: String, Sendable {
    case png, jpeg

    public var contentType: String { self == .png ? "image/png" : "image/jpeg" }
}

/// GET /api/v1/screenshot query, checked.
public struct APIScreenshotRequest: Equatable, Sendable {
    /// Wider than this is refused (a 6K display is 6016 pixels wide).
    public static let maxWidth = 8192
    public static let minWidth = 16
    public static let defaultJPEGQuality = 0.8

    public var target: APITarget
    public var format: APIImageFormat
    /// Requested width in pixels; nil = full size (the target's native pixels).
    public var width: Int?
    public var quality: Double

    public init(target: APITarget, format: APIImageFormat, width: Int?, quality: Double) {
        self.target = target; self.format = format; self.width = width; self.quality = quality
    }

    public static func parse(_ q: [String: String]) -> Result<APIScreenshotRequest, APIError> {
        let target: APITarget
        switch APITarget.parse(display: q["display"], window: q["window"]) {
        case .success(let t): target = t
        case .failure(let e): return .failure(e)
        }
        guard let format = APIImageFormat(rawValue: q["format"] ?? "png") else {
            return .failure(APIError("format must be png or jpeg."))
        }
        var width: Int?
        if let w = q["width"] {
            guard let n = Int(w), (minWidth...maxWidth).contains(n) else {
                return .failure(APIError("width must be a whole number from \(minWidth) to \(maxWidth)."))
            }
            width = n
        }
        var quality = defaultJPEGQuality
        if let s = q["quality"] {
            guard let v = Double(s), v > 0, v <= 1 else { return .failure(APIError("quality must be more than 0 and at most 1.")) }
            quality = v
        }
        return .success(APIScreenshotRequest(target: target, format: format, width: width, quality: quality))
    }
}

/// The coordinate contract. A screenshot of a target (a display, or one window) is `image` pixels
/// big and shows `target` (global points). An action's (x, y) are pixels of that screenshot:
///   pixels → global points:  point = target.origin + (x / image.w · target.w, y / image.h · target.h)
///   points → what ClientMessage.move takes: normalized 0…1 inside the display the point is on.
/// So coordinates stay right at any screenshot size and any display scale.
public enum APIGeometry {
    /// Pixel size of a screenshot: full size is points × scale; a requested width keeps the
    /// aspect ratio and is never larger than full size.
    public static func imageSize(points: CGSize, scale: Double, requestedWidth: Int?) -> APISize {
        let fullW = max(1, Int((Double(points.width) * scale).rounded()))
        let fullH = max(1, Int((Double(points.height) * scale).rounded()))
        guard let req = requestedWidth, req < fullW else { return APISize(w: fullW, h: fullH) }
        return APISize(w: req, h: max(1, Int((Double(req) * Double(fullH) / Double(fullW)).rounded())))
    }

    /// A screenshot pixel → global point, or nil when it's outside the image.
    public static func toPoint(x: Double, y: Double, image: APISize, target: CGRect) -> CGPoint? {
        guard image.w > 0, image.h > 0, x >= 0, y >= 0, x <= Double(image.w), y <= Double(image.h) else { return nil }
        return CGPoint(x: Double(target.minX) + x / Double(image.w) * Double(target.width),
                       y: Double(target.minY) + y / Double(image.h) * Double(target.height))
    }

    /// A global point → normalized 0…1 inside `display` (for ClientMessage.move), or nil when outside it.
    public static func toNormalized(_ point: CGPoint, display: CGRect) -> CGPoint? {
        WindowGeometry.toNormalized(point, in: display).map { CGPoint(x: min(max($0.x, 0), 1), y: min(max($0.y, 0), 1)) }
    }

    /// The display (of `displays`, by bounds in points) that contains a point, else the one whose
    /// centre is closest.
    public static func display(containing point: CGPoint, in displays: [(id: UInt32, bounds: CGRect)]) -> UInt32? {
        if let hit = displays.first(where: { $0.bounds.contains(point) }) { return hit.id }
        return displays.min { a, b in
            hypot(a.bounds.midX - point.x, a.bounds.midY - point.y) < hypot(b.bounds.midX - point.x, b.bounds.midY - point.y)
        }?.id
    }
}

/// POST /api/v1/actions: one checked action. Coordinates are pixels of the screenshot (see APIGeometry).
public enum APIAction: Equatable, Sendable {
    public enum Button: String, Sendable {
        case left, middle, right
        /// ClientMessage.button's index.
        public var index: Int { switch self { case .left: 0; case .middle: 1; case .right: 2 } }
    }

    case move(x: Double, y: Double)
    case click(x: Double, y: Double, button: Button, count: Int)
    case down(button: Button, at: CGPoint?)
    case up(button: Button, at: CGPoint?)
    case drag(from: CGPoint, to: CGPoint, button: Button)
    case scroll(dx: Double, dy: Double, at: CGPoint?)
    case key([String])
    case text(String)
    case openApp(String)
    case openURL(String)

    /// Whether it has coordinates (so the request needs `image`).
    public var hasCoordinates: Bool {
        switch self {
        case .move, .click, .drag: return true
        case .down(_, let at), .up(_, let at), .scroll(_, _, let at): return at != nil
        case .key, .text, .openApp, .openURL: return false
        }
    }
}

/// One ClientMessage to run, the display its normalized move is relative to, and a pause after it.
public struct APIStep: Equatable, Sendable {
    public var message: ClientMessage
    public var display: UInt32?
    public var pauseMs: Int
    public init(_ message: ClientMessage, display: UInt32? = nil, pauseMs: Int = 0) {
        self.message = message; self.display = display; self.pauseMs = pauseMs
    }
}

/// POST /api/v1/actions body, checked as a whole before any of it runs.
public struct APIActionRequest: Equatable, Sendable {
    public static let maxActions = 50
    public static let maxBytes = 64 * 1024
    public static let maxTextLength = 4096
    public static let maxClickCount = 3
    public static let maxScroll = 10_000.0
    /// A drag moves in this many steps, this far apart, so apps see the pointer travel.
    public static let dragSteps = 8
    public static let dragStepMs = 16

    public var target: APITarget
    public var image: APISize?
    public var actions: [APIAction]

    public init(target: APITarget, image: APISize?, actions: [APIAction]) {
        self.target = target; self.image = image; self.actions = actions
    }

    public static func parse(_ data: Data) -> Result<APIActionRequest, APIError> {
        guard data.count <= maxBytes else { return .failure(APIError("The request is over \(maxBytes / 1024) KB.")) }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(APIError("The body must be a JSON object."))
        }
        var target = APITarget.display(nil)
        if let t = obj["target"] {
            guard let t = t as? [String: Any] else { return .failure(APIError("target must be {\"display\": id} or {\"window\": id}.")) }
            let d = (t["display"] as? NSNumber).map { "\($0.int64Value)" }, w = (t["window"] as? NSNumber).map { "\($0.int64Value)" }
            switch APITarget.parse(display: d, window: w) {
            case .success(let parsed): target = parsed
            case .failure(let e): return .failure(e)
            }
        }
        var image: APISize?
        if let i = obj["image"] {
            guard let i = i as? [String: Any], let w = (i["w"] as? NSNumber)?.intValue, let h = (i["h"] as? NSNumber)?.intValue,
                  w > 0, h > 0, w <= APIScreenshotRequest.maxWidth, h <= APIScreenshotRequest.maxWidth else {
                return .failure(APIError("image must be {\"w\": pixels, \"h\": pixels}, the size of the screenshot."))
            }
            image = APISize(w: w, h: h)
        }
        guard let list = obj["actions"] as? [Any], !list.isEmpty else { return .failure(APIError("actions must be a list of at least one action.")) }
        guard list.count <= maxActions else { return .failure(APIError("At most \(maxActions) actions per call.")) }
        var actions: [APIAction] = []
        for (i, raw) in list.enumerated() {
            guard let a = raw as? [String: Any] else { return .failure(APIError("Each action must be a JSON object.", index: i)) }
            switch parseAction(a) {
            case .success(let action):
                if action.hasCoordinates, image == nil {
                    return .failure(APIError("Actions with x and y need image, the size of the screenshot they came from.", index: i))
                }
                actions.append(action)
            case .failure(let message):
                return .failure(APIError(message.error, index: i))
            }
        }
        return .success(APIActionRequest(target: target, image: image, actions: actions))
    }

    private static func parseAction(_ a: [String: Any]) -> Result<APIAction, APIError> {
        func num(_ k: String) -> Double? { (a[k] as? NSNumber).map(\.doubleValue).flatMap { $0.isFinite ? $0 : nil } }
        func point(_ xk: String, _ yk: String) -> CGPoint? { num(xk).flatMap { x in num(yk).map { CGPoint(x: x, y: $0) } } }
        func button() -> APIAction.Button? { a["button"] == nil ? .left : (a["button"] as? String).flatMap(APIAction.Button.init(rawValue:)) }
        let type = a["type"] as? String ?? ""
        let badButton = APIError("button must be left, middle or right.")
        switch type {
        case "move":
            guard let p = point("x", "y") else { return .failure(APIError("move needs x and y.")) }
            return .success(.move(x: p.x, y: p.y))
        case "click":
            guard let p = point("x", "y") else { return .failure(APIError("click needs x and y.")) }
            guard let b = button() else { return .failure(badButton) }
            let count = (a["count"] as? NSNumber)?.intValue ?? 1
            guard (1...maxClickCount).contains(count) else { return .failure(APIError("count must be 1 to \(maxClickCount).")) }
            return .success(.click(x: p.x, y: p.y, button: b, count: count))
        case "down", "up":
            guard let b = button() else { return .failure(badButton) }
            let at = point("x", "y")
            if at == nil, a["x"] != nil || a["y"] != nil { return .failure(APIError("\(type) needs both x and y, or neither.")) }
            return .success(type == "down" ? .down(button: b, at: at) : .up(button: b, at: at))
        case "drag":
            guard let from = point("x", "y"), let to = point("toX", "toY") else { return .failure(APIError("drag needs x, y, toX and toY.")) }
            guard let b = button() else { return .failure(badButton) }
            return .success(.drag(from: from, to: to, button: b))
        case "scroll":
            let dx = num("dx") ?? 0, dy = num("dy") ?? 0
            guard dx != 0 || dy != 0 else { return .failure(APIError("scroll needs dx or dy.")) }
            guard abs(dx) <= maxScroll, abs(dy) <= maxScroll else { return .failure(APIError("scroll is at most \(Int(maxScroll)) pixels.")) }
            let at = point("x", "y")
            if at == nil, a["x"] != nil || a["y"] != nil { return .failure(APIError("scroll needs both x and y, or neither.")) }
            return .success(.scroll(dx: dx, dy: dy, at: at))
        case "key":
            guard let keys = a["keys"] as? [String], !keys.isEmpty, keys.count <= 6 else {
                return .failure(APIError("key needs keys, a list of 1 to 6 key names."))
            }
            if let bad = keys.first(where: { KeyMap.keycode(for: $0) == nil }) {
                return .failure(APIError("\(bad) isn't a key name. Use KeyboardEvent.code names such as KeyA, Enter, MetaLeft."))
            }
            return .success(.key(keys))
        case "text":
            guard let t = a["text"] as? String, !t.isEmpty else { return .failure(APIError("text needs text.")) }
            guard t.count <= maxTextLength else { return .failure(APIError("text is at most \(maxTextLength) characters.")) }
            return .success(.text(t))
        case "openApp":
            guard let path = a["path"] as? String, !path.isEmpty else { return .failure(APIError("openApp needs path, from /api/v1/apps.")) }
            return .success(.openApp(path))
        case "openURL":
            guard let url = a["url"] as? String, SafeURL.validate(url) != nil else {
                return .failure(APIError("openURL needs url, a web link (http or https)."))
            }
            return .success(.openURL(url))
        default:
            return .failure(APIError("Unknown action type \"\(type)\"."))
        }
    }

    /// Every action's steps, or the first action whose coordinates fall outside the image.
    /// `resolve` maps a screenshot pixel to (display, normalized x, y); nil = outside.
    public func steps(resolve: (CGPoint) -> (display: UInt32, x: Double, y: Double)?) -> Result<[[APIStep]], APIError> {
        var all: [[APIStep]] = []
        for (i, action) in actions.enumerated() {
            var out: [APIStep] = []
            func move(_ p: CGPoint, pauseMs: Int = 0) -> Bool {
                guard let r = resolve(p) else { return false }
                out.append(APIStep(.move(x: r.x, y: r.y), display: r.display, pauseMs: pauseMs))
                return true
            }
            let outside = APIError("x and y must be inside the screenshot (\(image?.w ?? 0) × \(image?.h ?? 0) pixels).", index: i)
            switch action {
            case let .move(x, y):
                guard move(CGPoint(x: x, y: y)) else { return .failure(outside) }
            case let .click(x, y, button, count):
                guard move(CGPoint(x: x, y: y)) else { return .failure(outside) }
                for _ in 0..<count {
                    out.append(APIStep(.button(index: button.index, down: true)))
                    out.append(APIStep(.button(index: button.index, down: false)))
                }
            case let .down(button, at), let .up(button, at):
                if let at { guard move(at) else { return .failure(outside) } }
                let isDown: Bool = { if case .down = action { return true }; return false }()
                out.append(APIStep(.button(index: button.index, down: isDown)))
            case let .drag(from, to, button):
                guard move(from) else { return .failure(outside) }
                out.append(APIStep(.button(index: button.index, down: true), pauseMs: Self.dragStepMs))
                for s in 1...Self.dragSteps {
                    let f = Double(s) / Double(Self.dragSteps)
                    let p = CGPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f)
                    guard move(p, pauseMs: Self.dragStepMs) else { return .failure(outside) }
                }
                out.append(APIStep(.button(index: button.index, down: false)))
            case let .scroll(dx, dy, at):
                if let at { guard move(at) else { return .failure(outside) } }
                out.append(APIStep(.scroll(dx: dx, dy: dy)))
            case let .key(keys):
                for k in keys { out.append(APIStep(.key(code: k, down: true))) }
                for k in keys.reversed() { out.append(APIStep(.key(code: k, down: false))) }
            case let .text(t):
                out.append(APIStep(.text(t)))
            case let .openApp(path):
                out.append(APIStep(.openApp(path)))
            case let .openURL(url):
                out.append(APIStep(.openURL(url)))
            }
            all.append(out)
        }
        return .success(all)
    }
}

extension APIGeometry {
    /// The resolver APIActionRequest.steps takes: screenshot pixel → (display, normalized x, y),
    /// for a screenshot `image` pixels big showing `target` (points), over these displays.
    public static func resolver(image: APISize, target: CGRect, displays: [(id: UInt32, bounds: CGRect)])
        -> (CGPoint) -> (display: UInt32, x: Double, y: Double)? {
        { pixel in
            guard let point = toPoint(x: Double(pixel.x), y: Double(pixel.y), image: image, target: target),
                  let id = display(containing: point, in: displays),
                  let bounds = displays.first(where: { $0.id == id })?.bounds,
                  let n = toNormalized(point, display: bounds) else { return nil }
            return (id, Double(n.x), Double(n.y))
        }
    }
}

/// POST /api/v1/actions answer when every action ran.
public struct APIActionResult: Codable, Equatable, Sendable {
    public var ok: Bool
    public var done: Int
    public init(done: Int) { ok = true; self.done = done }
}

public enum APIJSON {
    /// Sorted keys, so answers are stable and easy to diff.
    public static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data(#"{"error":"Couldn't encode the answer."}"#.utf8)
    }
}
