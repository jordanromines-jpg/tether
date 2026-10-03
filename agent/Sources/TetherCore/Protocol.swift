import Foundation

/// Binary video frame layout (agent → client):
///   byte 0      message type (1 = video)
///   byte 1      flags (bit 0 = keyframe)
///   bytes 2..9  timestamp in microseconds, big-endian UInt64
///   bytes 10..  AVCC (length-prefixed) H.264 access unit
public enum VideoFrameHeader {
    public static let typeVideo: UInt8 = 1
    public static let size = 10

    public static func encode(isKeyframe: Bool, timestampMicros: UInt64, payload: Data) -> Data {
        var out = Data(capacity: size + payload.count)
        out.append(typeVideo)
        out.append(isKeyframe ? 1 : 0)
        withUnsafeBytes(of: timestampMicros.bigEndian) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    public static func decode(_ data: Data) -> (isKeyframe: Bool, timestampMicros: UInt64, payload: Data)? {
        guard data.count >= size, data[data.startIndex] == typeVideo else { return nil }
        let base = data.startIndex
        let flags = data[base + 1]
        var ts: UInt64 = 0
        for i in 0..<8 { ts = (ts << 8) | UInt64(data[base + 2 + i]) }
        return (flags & 1 == 1, ts, data.subdata(in: (base + size)..<data.endIndex))
    }
}

public enum AudioFormat: String, Sendable {
    case aac, pcm
}

/// Binary audio frame layout (agent → client):
///   byte 0      message type (2 = audio)
///   byte 1      format (1 = AAC-LC 48 kHz stereo raw frames, 2 = PCM s16le 24 kHz stereo)
///   bytes 2..9  timestamp in microseconds, big-endian UInt64
///   bytes 10..  payload
public enum AudioFrameHeader {
    public static let typeAudio: UInt8 = 2

    public static func encode(format: AudioFormat, timestampMicros: UInt64, payload: Data) -> Data {
        var out = Data(capacity: 10 + payload.count)
        out.append(typeAudio)
        out.append(format == .aac ? 1 : 2)
        withUnsafeBytes(of: timestampMicros.bigEndian) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }
}

public enum VideoCodec: String, Sendable {
    case h264, hevc
}

public enum H264 {
    /// WebCodecs codec string ("avc1.PPCCLL") from an avcC record.
    public static func codecString(avcC: Data) -> String? {
        guard avcC.count >= 4 else { return nil }
        let b = [UInt8](avcC.prefix(4))
        return String(format: "avc1.%02x%02x%02x", b[1], b[2], b[3])
    }
}

public enum HEVC {
    /// WebCodecs codec string (e.g. "hvc1.1.6.L153.B0") from an hvcC record (ISO/IEC 14496-15 §E.3).
    public static func codecString(hvcC: Data) -> String? {
        guard hvcC.count >= 13 else { return nil }
        let b = [UInt8](hvcC.prefix(13))
        let profileSpace = Int(b[1] >> 6)
        let tier = (b[1] >> 5) & 1
        let profileIdc = Int(b[1] & 0x1F)
        let compat = UInt32(b[2]) << 24 | UInt32(b[3]) << 16 | UInt32(b[4]) << 8 | UInt32(b[5])
        var reversed: UInt32 = 0
        for i in 0..<32 where compat & (1 << i) != 0 { reversed |= 1 << (31 - i) }
        let space = ["", "A", "B", "C"][profileSpace]
        var constraints = Array(b[6...11])
        while let last = constraints.last, last == 0 { constraints.removeLast() }
        var out = "hvc1.\(space)\(profileIdc).\(String(reversed, radix: 16, uppercase: true)).\(tier == 1 ? "H" : "L")\(b[12])"
        for c in constraints { out += "." + String(c, radix: 16, uppercase: true) }
        return out
    }
}

/// Messages a client sends as JSON text frames. Field `t` selects the type.
public enum ClientMessage: Equatable, Sendable {
    case hello(quality: String?, displayID: UInt32?, codecs: [VideoCodec])
    case quality(String)
    case display(UInt32)
    case keyframe
    case move(x: Double, y: Double)          // absolute, normalized 0…1 within the display
    case moveRelative(dx: Double, dy: Double) // normalized deltas
    case button(index: Int, down: Bool)       // 0 left, 1 middle, 2 right; at current position
    case scroll(dx: Double, dy: Double)       // pixels, browser convention (positive dy = scroll down)
    case key(code: String, down: Bool)        // KeyboardEvent.code
    case text(String)
    case setClipboard(String)
    case releaseAll
    case ping(id: Double)
    case audio(on: Bool, format: AudioFormat)
    case wake
    case fit(mode: String, width: Double, height: Double)
    case stats(rttMs: Double, decodeQueue: Int)

    public static func parse(_ text: String) -> ClientMessage? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["t"] as? String else { return nil }
        func num(_ k: String) -> Double? { (obj[k] as? NSNumber)?.doubleValue }
        func bool(_ k: String) -> Bool { (obj[k] as? Bool) ?? false }
        func str(_ k: String) -> String? { obj[k] as? String }
        switch t {
        case "hello":
            let codecs = (obj["codecs"] as? [String] ?? ["h264"]).compactMap(VideoCodec.init(rawValue:))
            return .hello(quality: str("quality"), displayID: num("display").map { UInt32($0) }, codecs: codecs)
        case "quality":
            return str("preset").map { .quality($0) }
        case "display":
            return num("id").map { .display(UInt32($0)) }
        case "keyframe":
            return .keyframe
        case "move":
            guard let x = num("x"), let y = num("y") else { return nil }
            return .move(x: x, y: y)
        case "mrel":
            guard let dx = num("dx"), let dy = num("dy") else { return nil }
            return .moveRelative(dx: dx, dy: dy)
        case "btn":
            return .button(index: Int(num("b") ?? 0), down: bool("down"))
        case "scroll":
            return .scroll(dx: num("dx") ?? 0, dy: num("dy") ?? 0)
        case "key":
            return str("code").map { .key(code: $0, down: bool("down")) }
        case "text":
            return str("s").map { .text($0) }
        case "setclip":
            return str("s").map { .setClipboard($0) }
        case "release":
            return .releaseAll
        case "audio":
            return .audio(on: bool("on"), format: AudioFormat(rawValue: str("format") ?? "") ?? .pcm)
        case "wake":
            return .wake
        case "fit":
            return .fit(mode: str("mode") ?? "off", width: num("w") ?? 0, height: num("h") ?? 0)
        case "ping":
            return .ping(id: num("id") ?? 0)
        case "stats":
            return .stats(rttMs: num("rtt") ?? 0, decodeQueue: Int(num("queue") ?? 0))
        default:
            return nil
        }
    }
}

/// Encodes an agent → client JSON control message.
public func jsonMessage(_ type: String, _ fields: [String: Any] = [:]) -> String {
    var obj = fields
    obj["t"] = type
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}
