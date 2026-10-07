import Foundation

/// Streaming quality presets the client can pick.
public enum QualityPreset: String, Sendable, CaseIterable {
    case saver, fast, balanced, sharp

    public var maxWidth: Int {
        switch self {
        case .saver: 960
        case .fast: 1280
        case .balanced: 1920
        case .sharp: 6144
        }
    }

    public var fps: Int {
        switch self {
        case .saver, .fast: 30
        case .balanced, .sharp: 60
        }
    }

    /// Average bitrate in bits per second.
    public var bitrate: Int {
        switch self {
        case .saver: 1_200_000
        case .fast: 2_500_000
        case .balanced: 8_000_000
        case .sharp: 20_000_000
        }
    }
}

public enum Sizing {
    /// Largest frame browsers' H.264 decoders reliably accept (level 5.1/5.2).
    public static let maxPixels = 3840 * 2160
    /// HEVC (level 6.x) comfortably covers 5K/6K Apple displays.
    public static let maxPixelsHEVC = 6016 * 3384

    public static func maxPixels(for codec: VideoCodec) -> Int { codec == .hevc ? maxPixelsHEVC : maxPixels }

    /// The widest picture worth sending to one device: the Mac's screen fitted into the device's
    /// screen (whichever way it's held), in device pixels, plus 25% for zooming in a little.
    /// - Parameters: `w`/`h` are the device's screen in CSS pixels, `dpr` its pixel ratio, `macAspect` width/height.
    public static func deviceCap(w: Double, h: Double, dpr: Double, macAspect: Double) -> Int {
        guard w > 0, h > 0, dpr > 0, macAspect > 0 else { return Int.max }
        let long = max(w, h) * dpr, short = min(w, h) * dpr
        let fitted = max(min(long, short * macAspect), min(short, long * macAspect))
        return Int(fitted * 1.25)
    }

    /// Scales a display's native pixel size down to fit `maxWidth` and the H.264
    /// frame limit, keeping aspect ratio and even dimensions.
    public static func encodeSize(nativeWidth: Int, nativeHeight: Int, maxWidth: Int, maxPixels: Int = Sizing.maxPixels) -> (width: Int, height: Int) {
        guard nativeWidth > 0, nativeHeight > 0 else { return (2, 2) }
        var scale = min(1.0, Double(maxWidth) / Double(nativeWidth))
        let pixels = Double(nativeWidth) * Double(nativeHeight) * scale * scale
        if pixels > Double(maxPixels) {
            scale *= (Double(maxPixels) / pixels).squareRoot()
        }
        func even(_ v: Double) -> Int { max(2, Int(v) & ~1) }
        return (even(Double(nativeWidth) * scale), even(Double(nativeHeight) * scale))
    }
}

/// "Sharp when still": when has the screen stopped moving?
public enum StillPolicy {
    /// After this long without real movement, one sharp frame goes out.
    public static let stillAfterMs = 500
    /// How a change is spotted: by the encoded size of each in-between (non-key) frame. An unchanged
    /// picture encodes to a few hundred bytes and a blinking caret to well under a kilobyte, so neither
    /// counts; a scroll or a new window does. (ScreenCaptureKit's dirty rects can't be used: in window
    /// mode they cover the whole window on every frame.)
    /// Frames to ignore after a keyframe while the encoder settles.
    public static let settleFrames = 3

    public static func isMotion(frameBytes: Int, pixels: Int) -> Bool {
        frameBytes > max(1_000, pixels / 1_000)
    }
}
