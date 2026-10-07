import Foundation

/// Per-second network/decoder health reported for one client.
public struct LinkStats: Sendable, Equatable {
    public var rttMs: Double          // round trip measured by client ping/pong
    public var decodeQueue: Int       // frames waiting in the client's decoder
    public var droppedFrames: Int     // frames the agent dropped for this client (backpressure)

    public init(rttMs: Double, decodeQueue: Int, droppedFrames: Int) {
        self.rttMs = rttMs
        self.decodeQueue = decodeQueue
        self.droppedFrames = droppedFrames
    }

    /// True when this client is falling behind.
    public func isCongested(baselineRttMs: Double) -> Bool {
        droppedFrames > 0 || decodeQueue > 4 || rttMs > baselineRttMs * 2 + 120
    }
}

/// Picks resolution and bitrate for "Auto" quality from the worst client's link health.
/// Pure and deterministic so it can be tested without a network.
public struct AdaptiveController: Sendable {
    /// Resolution ladder (max encode width).
    public static let widths = [1280, 1600, 1920, 2560, 3840]

    public struct Decision: Equatable, Sendable {
        public var maxWidth: Int
        public var bitrate: Int
        public var resolutionChanged: Bool
        public var bitrateChanged: Bool
    }

    public private(set) var level: Int
    public private(set) var bitrate: Int
    /// The highest rung worth climbing to: no point sending a phone more pixels than it can show.
    public private(set) var maxLevel = AdaptiveController.widths.count - 1
    public let fps: Int
    public let bitsPerPixel: Double
    private var clearSeconds = 0
    private var floorSeconds = 0
    private var baselineRtt: Double?

    /// - Parameters:
    ///   - bitsPerPixel: ~0.07 for H.264, ~0.045 for HEVC (HEVC needs fewer bits for the same quality).
    public init(startLevel: Int = 2, fps: Int = 60, bitsPerPixel: Double = 0.07) {
        self.level = max(0, min(startLevel, Self.widths.count - 1))
        self.fps = fps
        self.bitsPerPixel = bitsPerPixel
        self.bitrate = 0
        self.bitrate = maxBitrate(level)
    }

    public var maxWidth: Int { Self.widths[level] }

    /// The largest rung no wider than `width` (never below the first). `Int.max` = no limit.
    public static func level(fitting width: Int) -> Int {
        widths.lastIndex { $0 <= width } ?? 0
    }

    /// Limits the ladder to what the connected devices can show. Returns true when that lowered the
    /// current resolution (capture must restart).
    @discardableResult
    public mutating func setMaxLevel(_ newMax: Int) -> Bool {
        maxLevel = max(0, min(newMax, Self.widths.count - 1))
        guard level > maxLevel else { return false }
        level = maxLevel
        bitrate = min(bitrate, maxBitrate(level))
        return true
    }

    public func maxBitrate(_ level: Int) -> Int {
        let w = Double(Self.widths[level]), h = w * 9 / 16
        return Int(w * h * Double(fps) * bitsPerPixel)
    }

    public func minBitrate(_ level: Int) -> Int { max(800_000, maxBitrate(level) / 4) }

    /// Feed one second of the worst client's stats; returns what to apply.
    public mutating func update(_ stats: LinkStats) -> Decision {
        let previousLevel = level, previousBitrate = bitrate
        baselineRtt = min(baselineRtt ?? stats.rttMs, stats.rttMs > 0 ? stats.rttMs : .infinity)
        let congested = stats.isCongested(baselineRttMs: baselineRtt ?? stats.rttMs)

        if congested {
            clearSeconds = 0
            let lowered = Int(Double(bitrate) * 0.7)
            if lowered >= minBitrate(level) {
                bitrate = lowered
                floorSeconds = 0
            } else {
                bitrate = minBitrate(level)
                floorSeconds += 1
                if floorSeconds >= 2, level > 0 {
                    level -= 1
                    bitrate = maxBitrate(level) / 2
                    floorSeconds = 0
                }
            }
        } else {
            floorSeconds = 0
            clearSeconds += 1
            if clearSeconds >= 5, bitrate < maxBitrate(level) {
                bitrate = min(maxBitrate(level), Int(Double(bitrate) * 1.15))
                clearSeconds = 0
            } else if clearSeconds >= 10, bitrate >= maxBitrate(level), level < maxLevel {
                level += 1
                bitrate = maxBitrate(level) / 2
                clearSeconds = 0
            }
        }
        return Decision(maxWidth: maxWidth, bitrate: bitrate,
                        resolutionChanged: level != previousLevel, bitrateChanged: bitrate != previousBitrate)
    }
}
