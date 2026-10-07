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

// Setup Assistant: Tailscale status, when to open, shortcut registry
do {
    let ok = Data(#"{"BackendState":"Running","Self":{"DNSName":"studio.tail1234.ts.net."},"CertDomains":["studio.tail1234.ts.net"]}"#.utf8)
    let s = TailnetStatus.parse(ok)
    expect(s.running && !s.needsLogin, "running tailnet")
    expect(s.dnsName == "studio.tail1234.ts.net", "trailing dot removed from DNS name")
    expect(s.url == "https://studio.tail1234.ts.net", "link built from DNS name")
    expect(s.httpsEnabled, "HTTPS certificates detected")
    let noCerts = TailnetStatus.parse(Data(#"{"BackendState":"Running","Self":{"DNSName":"a.b.ts.net."},"CertDomains":null}"#.utf8))
    expect(noCerts.running && !noCerts.httpsEnabled, "null CertDomains means HTTPS off")
    let login = TailnetStatus.parse(Data(#"{"BackendState":"NeedsLogin","Self":{"DNSName":""}}"#.utf8))
    expect(!login.running && login.needsLogin && login.dnsName == nil, "signed-out tailnet")
    expect(TailnetStatus.parse(Data("not json".utf8)) == .unavailable, "garbage is unavailable")

    expect(SetupPolicy.shouldOpenAssistant(onboarded: false, requested: false, screenAllowed: true, inputAllowed: true), "first launch opens")
    expect(!SetupPolicy.shouldOpenAssistant(onboarded: true, requested: false, screenAllowed: true, inputAllowed: true), "set up and allowed stays closed")
    expect(SetupPolicy.shouldOpenAssistant(onboarded: true, requested: false, screenAllowed: false, inputAllowed: true), "missing Screen Recording opens")
    expect(SetupPolicy.shouldOpenAssistant(onboarded: true, requested: false, screenAllowed: true, inputAllowed: false), "missing Accessibility opens")
    expect(SetupPolicy.shouldOpenAssistant(onboarded: true, requested: true, screenAllowed: true, inputAllowed: true), "tether://setup opens")

    var reg = ShortcutRegistry(json: Data(#"["/Applications/Tether", "relative/path", 3]"#.utf8))
    expect(reg.paths == ["/Applications/Tether"], "registry keeps only absolute paths")
    reg.add("/Applications/Tether")
    reg.add("/Users/me/Desktop/Tether")
    expect(reg.paths.count == 2, "registry has no duplicates")
    reg.remove("/Applications/Tether")
    expect(ShortcutRegistry(json: reg.json).paths == ["/Users/me/Desktop/Tether"], "registry round-trips through JSON")
    expect(ShortcutRegistry(json: nil).paths.isEmpty, "missing registry is empty")
}

// v4 protocol and policy
do {
    expect(ClientMessage.parse(#"{"t":"observe","on":true}"#) == .observe(true), "observe parses")
    expect(ClientMessage.parse(#"{"t":"curtain","on":false}"#) == .curtain(false), "curtain parses")
    expect(ClientMessage.parse(#"{"t":"action","name":"volumeUp"}"#) == .action(.volumeUp), "quick action parses")
    expect(ClientMessage.parse(#"{"t":"action","name":"rm -rf"}"#) == nil, "unknown action rejected")
    expect(ClientMessage.parse(#"{"t":"openURL","url":"https://example.com"}"#) == .openURL("https://example.com"), "openURL parses")
    expect(ClientMessage.parse(#"{"t":"openApp","path":"/Applications/Calculator.app"}"#) == .openApp("/Applications/Calculator.app"), "openApp parses")
    expect(ClientMessage.parse(#"{"t":"windows"}"#) == .windows, "windows parses")
    expect(ClientMessage.parse(#"{"t":"focusWindow","id":42}"#) == .focusWindow(42), "focusWindow parses")
    expect(ClientMessage.parse(#"{"t":"captureWindow","id":7,"fit":true}"#) == .captureWindow(7, fit: true), "captureWindow parses")
    expect(ClientMessage.parse(#"{"t":"captureWindow"}"#) == .captureWindow(nil, fit: false), "captureWindow without id = whole screen")
    expect(ClientMessage.parse(#"{"t":"activity"}"#) == .activity, "activity parses")

    for m: ClientMessage in [.move(x: 0, y: 0), .key(code: "KeyA", down: true), .text("x"), .setClipboard("x"),
                             .action(.mute), .openURL("https://a.b"), .curtain(true), .captureWindow(1, fit: false), .wake] {
        expect(InputPolicy.isControl(m), "\(m) is control (blocked when view only)")
    }
    for m: ClientMessage in [.quality("fast"), .display(1), .ping(id: 1), .stats(rttMs: 1, decodeQueue: 0), .windows,
                             .audio(on: true, format: .aac), .observe(true), .keyframe] {
        expect(!InputPolicy.isControl(m), "\(m) is allowed when view only")
    }
    expect(InputPolicy.isActivity(.activity) && InputPolicy.isActivity(.scroll(dx: 0, dy: 1)), "activity counts")
    expect(!InputPolicy.isActivity(.ping(id: 1)), "pings don't count as activity")

    expect(SafeURL.validate("https://example.com/a?b=c") != nil, "https link allowed")
    expect(SafeURL.validate("  http://example.com ") != nil, "http link allowed, trimmed")
    for bad in ["file:///etc/passwd", "javascript:alert(1)", "x-apple.systempreferences:com.apple", "https://", "not a url",
                "https://" + String(repeating: "a", count: 5000) + ".com"] {
        expect(SafeURL.validate(bad) == nil, "\(bad.prefix(30)) rejected")
    }

    expect(QuickAction.volumeUp.mediaKey == 0 && QuickAction.mute.mediaKey == 7 && QuickAction.next.mediaKey == 17, "media key codes")
    expect(QuickAction.lockScreen.combo == ["ControlLeft", "MetaLeft", "KeyQ"] && QuickAction.sleepDisplay.mediaKey == nil, "combo actions")
    for a in QuickAction.allCases { expect(a.mediaKey != nil || a.combo != nil || a == .sleepDisplay, "\(a) has a way to run") }

    expect(Links.repo(fromRemote: "https://github.com/someone/tether.git") == "someone/tether", "repo from https remote")
    expect(Links.repo(fromRemote: "git@github.com:someone/fork.git") == "someone/fork", "repo from ssh remote")
    expect(Links.repo(fromRemote: "https://gitlab.com/x/y") == nil, "non-GitHub remote ignored")
    expect(Links.urls(repo: "a/b")["issues"] == "https://github.com/a/b/issues/new", "issues link")

    expect(TetherMarker.isRemote(eventUserData: TetherMarker.eventUserData), "marker recognised")
    expect(!TetherMarker.isRemote(eventUserData: 0), "physical events have no marker")
}

// v4 batch 2: battery saver, activity log, update check
do {
    let saver = QualityPreset.saver
    expect(saver.maxWidth == 960 && saver.fps == 30 && saver.bitrate == 1_200_000, "battery saver preset")
    expect(QualityPreset(rawValue: "saver") == .saver, "saver parses from the client")
    expect(saver.bitrate < QualityPreset.fast.bitrate, "saver uses less than fast")

    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var log = ActivityLog(limit: 3)
    let ids = (0..<4).map { _ in UUID() }
    for (i, id) in ids.enumerated() {
        log.started(ActivityEntry(id: id, login: "owner@example.com", device: "Device \(i)", start: t0.addingTimeInterval(Double(i) * 60)))
    }
    expect(log.entries.count == 3 && log.entries.first?.device == "Device 3", "log keeps the newest, newest first")
    log.ended(id: ids[3], at: t0.addingTimeInterval(180 + 65 * 60), viewOnly: true)
    expect(log.entries[0].durationText() == "1 h 5 min" && log.entries[0].viewOnly, "ended session duration and view-only flag")
    expect(log.entries[1].durationText() == "now", "open session reads now")
    log.closeDangling(at: t0.addingTimeInterval(200))
    expect(log.entries.allSatisfy { $0.end != nil }, "dangling sessions closed after a restart")
    let round = ActivityLog(json: log.json, limit: 3)
    expect(round == log, "activity log round-trips through JSON")
    expect(ActivityLog(json: Data("garbage".utf8)).entries.isEmpty, "bad activity file is empty, not a crash")
    var short = ActivityEntry(id: UUID(), login: "a", device: "b", start: t0)
    short.end = t0.addingTimeInterval(20)
    expect(short.durationText() == "under a minute", "short session wording")

    let gh = Data(#"{"sha":"abc","commit":{"committer":{"date":"2026-10-06T18:00:00Z"}}}"#.utf8)
    let remote = UpdateCheck.latestCommitDate(gh)
    expect(remote != nil, "GitHub commit date parsed")
    let build = ISO8601DateFormatter().date(from: "2026-10-01T09:00:00Z")
    expect(UpdateCheck.isNewer(remote: remote, build: build), "newer commit means an update")
    expect(!UpdateCheck.isNewer(remote: build, build: remote), "older remote is not an update")
    expect(!UpdateCheck.isNewer(remote: remote, build: remote), "same commit is not an update")
    expect(!UpdateCheck.isNewer(remote: remote, build: nil), "unknown build date never nags")
    expect(UpdateCheck.latestCommitDate(Data("{}".utf8)) == nil, "unexpected GitHub reply ignored")
}

print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
