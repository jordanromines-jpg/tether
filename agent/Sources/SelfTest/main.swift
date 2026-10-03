import Foundation
import CryptoKit
import TetherCore

var failures = 0
var checks = 0
func expect(_ cond: @autoclosure () -> Bool, _ label: String, line: Int = #line) {
    checks += 1
    if !cond() { failures += 1; print("FAIL line \(line): \(label)") }
}

// Auth
do {
    let p = AuthPolicy(allowedLoginsList: "Owner@Example.com", devMode: false)
    expect(p.isAllowed(login: "owner@example.com"), "allowlisted login (case-insensitive)")
    expect(!p.isAllowed(login: "someone@else.com"), "other login rejected")
    expect(!p.isAllowed(login: nil), "missing header rejected")
    expect(!p.isAllowed(login: ""), "empty header rejected")
    let dev = AuthPolicy(allowedLoginsList: "a@b.com", devMode: true)
    expect(dev.isAllowed(login: nil), "dev mode allows header-less")
    expect(!dev.isAllowed(login: "x@y.com"), "dev mode still rejects wrong login")
}

// Sizing
do {
    let a = Sizing.encodeSize(nativeWidth: 5120, nativeHeight: 2880, maxWidth: 1920)
    expect(a.width == 1920 && a.height == 1080, "5K → 1080p for auto")
    for (w, h) in [(5120, 2880), (6016, 3384), (3840, 2160)] {
        let b = Sizing.encodeSize(nativeWidth: w, nativeHeight: h, maxWidth: 6144)
        expect(b.width * b.height <= Sizing.maxPixels, "\(w)x\(h) within H.264 limit")
        expect(b.width % 2 == 0 && b.height % 2 == 0, "\(w)x\(h) even dimensions")
    }
    let c = Sizing.encodeSize(nativeWidth: 1280, nativeHeight: 800, maxWidth: 1920)
    expect(c.width == 1280 && c.height == 800, "never upscales")
}

// Protocol
do {
    let payload = Data([0, 0, 0, 2, 0x65, 0x88])
    let enc = VideoFrameHeader.encode(isKeyframe: true, timestampMicros: 123_456_789, payload: payload)
    let dec = VideoFrameHeader.decode(enc)
    expect(enc.count == VideoFrameHeader.size + payload.count, "frame size")
    expect(dec?.isKeyframe == true && dec?.timestampMicros == 123_456_789 && dec?.payload == payload, "frame round-trip")
    expect(H264.codecString(avcC: Data([1, 0x64, 0x00, 0x2A, 0xFF])) == "avc1.64002a", "codec string")
    expect(ClientMessage.parse(#"{"t":"move","x":0.5,"y":0.25}"#) == .move(x: 0.5, y: 0.25), "parse move")
    expect(ClientMessage.parse(#"{"t":"key","code":"KeyA","down":true}"#) == .key(code: "KeyA", down: true), "parse key")
    expect(ClientMessage.parse(#"{"t":"btn","b":2,"down":false}"#) == .button(index: 2, down: false), "parse btn")
    expect(ClientMessage.parse(#"{"t":"setclip","s":"hi"}"#) == .setClipboard("hi"), "parse setclip")
    expect(ClientMessage.parse(#"{"t":"nope"}"#) == nil, "unknown type ignored")
    expect(ClientMessage.parse("garbage") == nil, "garbage ignored")
}

// Key map
do {
    expect(KeyMap.keycode(for: "KeyA") == 0x00, "KeyA")
    expect(KeyMap.keycode(for: "Enter") == 0x24, "Enter")
    expect(KeyMap.keycode(for: "ArrowUp") == 0x7E, "ArrowUp")
    expect(KeyMap.modifier(forKeycode: 0x37) == .command, "MetaLeft is command")
    expect(KeyMap.modifier(forKeycode: 0x00) == nil, "A is not a modifier")
}

// HEVC codec string (Main profile, level 5.1, constraint byte 0xB0)
do {
    var hvcC = Data([1, 0x01, 0x60, 0, 0, 0, 0xB0, 0, 0, 0, 0, 0, 153])
    hvcC.append(contentsOf: [0xF0, 0x00])
    expect(HEVC.codecString(hvcC: hvcC) == "hvc1.1.6.L153.B0", "hevc main L5.1 → \(HEVC.codecString(hvcC: hvcC) ?? "nil")")
    let main10 = Data([1, 0x02, 0x20, 0, 0, 0, 0x90, 0, 0, 0, 0, 0, 120])
    expect(HEVC.codecString(hvcC: main10) == "hvc1.2.4.L120.90", "hevc main10 → \(HEVC.codecString(hvcC: main10) ?? "nil")")
    expect(HEVC.codecString(hvcC: Data([1, 2])) == nil, "short hvcC rejected")
    let hevc5k = Sizing.encodeSize(nativeWidth: 5120, nativeHeight: 2880, maxWidth: 6144, maxPixels: Sizing.maxPixels(for: .hevc))
    expect(hevc5k.width == 5120 && hevc5k.height == 2880, "HEVC streams 5K natively")
    expect(ClientMessage.parse(#"{"t":"hello","codecs":["hevc","h264"]}"#) == .hello(quality: nil, displayID: nil, codecs: [.hevc, .h264]), "hello codecs")
    expect(ClientMessage.parse(#"{"t":"stats","rtt":42,"queue":1}"#) == .stats(rttMs: 42, decodeQueue: 1), "stats message")
}

// Adaptive quality
do {
    var c = AdaptiveController(startLevel: 2)
    let start = c.bitrate
    let bad = LinkStats(rttMs: 40, decodeQueue: 0, droppedFrames: 3)
    let good = LinkStats(rttMs: 40, decodeQueue: 0, droppedFrames: 0)
    _ = c.update(good)  // establish baseline
    let d1 = c.update(bad)
    expect(d1.bitrateChanged && c.bitrate < start, "congestion lowers bitrate")
    for _ in 0..<12 { _ = c.update(bad) }
    expect(c.maxWidth < 1920, "sustained congestion lowers resolution (now \(c.maxWidth))")
    expect(c.bitrate >= c.minBitrate(c.level), "bitrate never below floor")
    let lowWidth = c.maxWidth
    for _ in 0..<120 { _ = c.update(good) }
    expect(c.maxWidth > lowWidth, "clear link climbs back up (now \(c.maxWidth))")
    var r = AdaptiveController(startLevel: 2)
    _ = r.update(good)
    let spike = r.update(LinkStats(rttMs: 400, decodeQueue: 0, droppedFrames: 0))
    expect(spike.bitrateChanged, "RTT spike counts as congestion")
}

// File sandbox
do {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("tether-sandbox-\(UUID().uuidString)")
    let root = tmp.appendingPathComponent("Downloads")
    try? fm.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
    fm.createFile(atPath: tmp.appendingPathComponent("secret.txt").path, contents: Data("x".utf8))
    try? fm.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: tmp)
    let box = FileSandbox(roots: ["downloads": root])
    expect(box.resolve(root: "downloads", relativePath: "") != nil, "root itself allowed")
    expect(box.resolve(root: "downloads", relativePath: "sub")?.lastPathComponent == "sub", "subfolder allowed")
    expect(box.resolve(root: "downloads", relativePath: "../secret.txt") == nil, "dot-dot escape rejected")
    expect(box.resolve(root: "downloads", relativePath: "sub/../../secret.txt") == nil, "nested dot-dot rejected")
    expect(box.resolve(root: "downloads", relativePath: "escape/secret.txt") == nil, "symlink escape rejected")
    expect(box.resolve(root: "desktop", relativePath: "") == nil, "unknown root rejected")
    expect(box.resolve(root: "downloads", relativePath: "/etc/passwd")?.path.hasSuffix("/Downloads/etc/passwd") ?? true,
           "absolute path stays inside root")
    try? fm.removeItem(at: tmp)
}

// Passkeys (simulated authenticator)
do {
    let priv = P256.Signing.PrivateKey()
    let spki = priv.publicKey.derRepresentation
    let origin = "https://mac.example.ts.net", rp = "mac.example.ts.net"
    let challenge = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    func clientData(_ type: String, _ ch: Data, _ org: String) -> Data {
        Data(#"{"type":"\#(type)","challenge":"\#(Passkey.base64urlEncode(ch))","origin":"\#(org)","crossOrigin":false}"#.utf8)
    }
    func authData(rp: String, flags: UInt8) -> Data {
        Data(SHA256.hash(data: Data(rp.utf8))) + Data([flags, 0, 0, 0, 1])
    }
    func assert(_ cd: Data, _ ad: Data, key: P256.Signing.PrivateKey = priv) -> Data {
        try! key.signature(for: ad + Data(SHA256.hash(data: cd))).derRepresentation
    }
    let regCD = clientData("webauthn.create", challenge, origin)
    expect((try? Passkey.verifyRegistration(clientDataJSON: regCD, publicKeySPKI: spki, challenge: challenge, origin: origin)) != nil, "registration accepted")
    expect((try? Passkey.verifyRegistration(clientDataJSON: regCD, publicKeySPKI: spki, challenge: Data([1]), origin: origin)) == nil, "registration with wrong challenge rejected")

    let cd = clientData("webauthn.get", challenge, origin)
    let ad = authData(rp: rp, flags: 0x05)
    func verify(_ cd: Data, _ ad: Data, _ sig: Data, origin o: String = origin, rp r: String = rp) -> Passkey.Failure? {
        do { try Passkey.verifyAssertion(clientDataJSON: cd, authenticatorData: ad, signature: sig, publicKeySPKI: spki,
                                         challenge: challenge, origin: o, rpID: r); return nil }
        catch let f as Passkey.Failure { return f } catch { return .badSignature }
    }
    expect(verify(cd, ad, assert(cd, ad)) == nil, "valid assertion accepted")
    expect(verify(cd, ad, assert(cd, ad, key: P256.Signing.PrivateKey())) == .badSignature, "other key's signature rejected")
    expect(verify(cd, ad, assert(cd, ad), origin: "https://evil.example") == .wrongOrigin, "wrong origin rejected")
    let adOtherRP = authData(rp: "evil.example", flags: 0x05)
    expect(verify(cd, adOtherRP, assert(cd, adOtherRP)) == .wrongRelyingParty, "wrong relying party rejected")
    let adNoUV = authData(rp: rp, flags: 0x01)
    expect(verify(cd, adNoUV, assert(cd, adNoUV)) == .userNotVerified, "missing Face ID / Touch ID rejected")
    let cdReplay = clientData("webauthn.get", Data([9, 9]), origin)
    expect(verify(cdReplay, ad, assert(cdReplay, ad)) == .wrongChallenge, "stale challenge rejected")
    var tampered = ad; tampered[tampered.count - 1] ^= 0xFF
    expect(verify(cd, tampered, assert(cd, ad)) == .badSignature, "tampered authenticator data rejected")

    let tokens = SessionToken(secret: Data(repeating: 7, count: 32))
    let t = tokens.issue(login: "Owner@Example.com", expires: Date().addingTimeInterval(60))
    expect(tokens.isValid(t, login: "owner@example.com"), "session token valid")
    expect(!tokens.isValid(t, login: "other@example.com"), "token bound to login")
    expect(!tokens.isValid(t, login: "owner@example.com", now: Date().addingTimeInterval(120)), "token expires")
    expect(!SessionToken(secret: Data(repeating: 8, count: 32)).isValid(t, login: "owner@example.com"), "token needs the secret")
    expect(!tokens.isValid(t.replacingOccurrences(of: "owner", with: "0wner"), login: "0wner@example.com"), "forged token rejected")
}

print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
