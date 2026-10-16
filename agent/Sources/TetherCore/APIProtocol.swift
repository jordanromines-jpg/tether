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

public enum APIJSON {
    /// Sorted keys, so answers are stable and easy to diff.
    public static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data(#"{"error":"Couldn't encode the answer."}"#.utf8)
    }
}
