import AppKit
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import CryptoKit
import NIOFoundationCompat
import TetherCore

let tailscaleLoginHeader = HTTPField.Name("Tailscale-User-Login")!

/// Rejects every request whose verified Tailscale identity isn't allowlisted.
struct TailscaleAuthMiddleware<Context: RequestContext>: RouterMiddleware {
    let policy: AuthPolicy

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard policy.isAllowed(login: request.headers[tailscaleLoginHeader]) else {
            context.logger.warning("Denied \(request.uri.path) for \(request.headers[tailscaleLoginHeader] ?? "<no identity>")")
            return Response(status: .forbidden, body: .init(byteBuffer: ByteBuffer(string: "Not authorized for Tether\n")))
        }
        return try await next(request, context)
    }
}

/// While remote access is paused from the menu bar, everything except the static web app
/// (which shows "Paused on the Mac") is refused.
struct PauseMiddleware<Context: RequestContext>: RouterMiddleware {
    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let path = request.uri.path
        let api = path == "/ws" || path == "/upload" || path == "/files" || path == "/download" || path == "/apps"
            || path == "/thumbnail" || path == "/clipboard/image" || path == "/reveal"
            || path == "/peers" || path.hasPrefix("/auth/")
        if AppState.shared.paused, api {
            let body = #"{"paused":true,"msg":"Remote access is paused on the Mac. Resume it from the Tether menu-bar icon."}"#
            return Response(status: .serviceUnavailable, headers: [.contentType: "application/json; charset=utf-8"],
                            body: .init(byteBuffer: ByteBuffer(string: body)))
        }
        return try await next(request, context)
    }
}

/// When the passkey lock is on, the screen, input and file endpoints also need a valid session cookie.
struct PasskeyGateMiddleware<Context: RequestContext>: RouterMiddleware {
    static var protectedPaths: Set<String> { ["/ws", "/upload", "/files", "/download", "/apps", "/thumbnail", "/clipboard/image", "/reveal"] }

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        if PasskeyStore.shared.required, Self.protectedPaths.contains(request.uri.path),
           !PasskeyStore.shared.sessionIsValid(cookieHeader: request.headers[.cookie], login: Server.login(request)) {
            return Response(status: .unauthorized, body: .init(byteBuffer: ByteBuffer(string: "Passkey required\n")))
        }
        return try await next(request, context)
    }
}

enum Server {
    static func login(_ request: Request) -> String { (request.headers[tailscaleLoginHeader] ?? "local").lowercased() }

    /// The page's origin as the browser sees it (https://<machine>.<tailnet>.ts.net).
    static var publicURL: String?

    static func origin(_ request: Request) -> (origin: String, rpID: String) {
        // Behind `tailscale serve` the browser's host may arrive as X-Forwarded-Host, or the
        // proxy may rewrite Host to 127.0.0.1; fall back to the published URL in that case.
        var authority = request.headers[HTTPField.Name("X-Forwarded-Host")!] ?? request.head.authority ?? "localhost"
        if authority.hasPrefix("127.0.0.1"), let pub = publicURL.flatMap(URL.init(string:))?.host { authority = pub }
        let host = authority.split(separator: ":").first.map(String.init) ?? authority
        let scheme = host == "localhost" ? "http" : "https"
        return ("\(scheme)://\(authority)", host)
    }

    static func run(port: Int, webDirectory: String, policy: AuthPolicy, publicURL: String?) async throws {
        let router = Router(context: BasicWebSocketRequestContext.self)
        let tailnetSuffix = Peers.tailnetSuffix(publicURL: publicURL)
        /// CORS for pages on this tailnet's other Macs (https://<machine>.<tailnet>.ts.net), no credentials.
        @Sendable func allowTailnetOrigin(_ request: Request, _ response: inout Response) {
            if let origin = request.headers[.origin], let suffix = tailnetSuffix,
               let host = URL(string: origin)?.host, origin.hasPrefix("https://"), host.hasSuffix("." + suffix) {
                response.headers[.accessControlAllowOrigin] = origin
                response.headers[.vary] = "Origin"
            }
        }
        Server.publicURL = publicURL
        router.middlewares.add(TailscaleAuthMiddleware(policy: policy))
        router.middlewares.add(PauseMiddleware())
        router.middlewares.add(PasskeyGateMiddleware())
        router.middlewares.add(FileMiddleware(
            webDirectory,
            cacheControl: .init([(MediaType(type: .any), [.noCache])]),
            searchForIndexHtml: true))

        router.get("healthz") { request, _ -> Response in
            var response = json(["ok": true, "name": Host.current().localizedName ?? "Mac", "perms": Permissions.json,
                                 "paused": AppState.shared.paused,
                                 "clients": Hub.shared.queue.sync { Hub.shared.clients.count },
                                 "keepAwake": Hub.shared.keepAwake,
                                 "curtain": Curtain.shared.status(), "wake": WakeInfo.json ?? NSNull()])
            // Let the Tether page on another of your Macs (same tailnet) see that this one is up.
            allowTailnetOrigin(request, &response)
            return response
        }

        // Also readable from another of your Macs' pages: when one Mac can't be reached, the page
        // asks the others when Tailscale last saw it. Still identity-gated like everything else.
        router.get("peers") { request, _ -> Response in
            var response = json(["peers": Peers.list()])
            allowTailnetOrigin(request, &response)
            return response
        }

        // Wake another of your Macs on this Mac's network (Wake-on-LAN). Called from your page on a
        // Mac that's asleep, so it's readable from your other Macs' pages too. Identity-gated like
        // everything else; a magic packet can only wake a machine, nothing more.
        router.post("wake") { request, _ -> Response in
            guard let mac = request.uri.queryParameters.get("mac").flatMap({ WakeOnLAN.parseMAC(String($0)) }) else {
                var r = json(["error": "That isn't a hardware address."], status: .badRequest)
                allowTailnetOrigin(request, &r)
                return r
            }
            let sent = WakeInfo.wake(mac: mac)
            NSLog("Tether: wake packet for \(WakeOnLAN.formatMAC(mac)) \(sent ? "sent" : "failed")")
            var r = json(["ok": sent], status: sent ? .ok : .internalServerError)
            allowTailnetOrigin(request, &r)
            return r
        }

        // ---- Passkey lock (WebAuthn) ----
        router.get("auth/status") { request, _ -> Response in
            let store = PasskeyStore.shared, login = login(request)
            return json(["required": store.required, "enrolled": !store.credentials(for: login).isEmpty,
                         "enrolling": store.enrolling,
                         "ok": !store.required || store.sessionIsValid(cookieHeader: request.headers[.cookie], login: login)])
        }

        // Forget this browser's unlock (used when a device pauses for being idle), so the next
        // connection asks for Face ID / Touch ID again.
        router.post("auth/lock") { _, _ -> Response in
            var response = json(["locked": true])
            response.headers[.setCookie] = "\(PasskeyStore.cookieName)=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Strict"
            return response
        }

        router.post("auth/register/options") { request, _ -> Response in
            let store = PasskeyStore.shared, login = login(request)
            guard store.enrolling else {
                return json(["error": "To add a passkey, choose “Add a passkey…” in the Tether menu on the Mac first."], status: .forbidden)
            }
            let challenge = store.newChallenge(for: "reg:" + login)
            let userID = Data(SHA256Digest.of(login).prefix(16))
            return json(["challenge": Passkey.base64urlEncode(challenge), "rpId": origin(request).rpID,
                         "userId": Passkey.base64urlEncode(userID), "name": login,
                         "exclude": store.credentials(for: login).map(\.id)])
        }

        router.post("auth/register") { request, _ -> Response in
            let store = PasskeyStore.shared, login = login(request)
            guard store.enrolling else { return Response(status: .forbidden) }
            let body = try await jsonBody(request)
            guard let id = body["id"] as? String, let pk = (body["publicKey"] as? String).flatMap(Passkey.base64urlDecode),
                  let cd = (body["clientDataJSON"] as? String).flatMap(Passkey.base64urlDecode),
                  let challenge = store.takeChallenge(for: "reg:" + login) else { return Response(status: .badRequest) }
            do {
                try Passkey.verifyRegistration(clientDataJSON: cd, publicKeySPKI: pk, challenge: challenge, origin: origin(request).origin)
            } catch {
                return json(["error": "Passkey registration failed (\(error))."], status: .badRequest)
            }
            store.add(.init(id: id, publicKey: pk.base64EncodedString(), login: login,
                            device: body["device"] as? String ?? "device", created: Date()))
            var response = json(["ok": true])
            response.headers[.setCookie] = store.sessionCookie(login: login)
            return response
        }

        router.post("auth/options") { request, _ -> Response in
            let store = PasskeyStore.shared, login = login(request)
            let challenge = store.newChallenge(for: "auth:" + login)
            return json(["challenge": Passkey.base64urlEncode(challenge), "rpId": origin(request).rpID,
                         "allow": store.credentials(for: login).map(\.id)])
        }

        router.post("auth/verify") { request, _ -> Response in
            let store = PasskeyStore.shared, login = login(request)
            let body = try await jsonBody(request)
            guard let id = body["id"] as? String,
                  let cred = store.credentials(for: login).first(where: { $0.id == id }),
                  let pk = Data(base64Encoded: cred.publicKey),
                  let cd = (body["clientDataJSON"] as? String).flatMap(Passkey.base64urlDecode),
                  let ad = (body["authenticatorData"] as? String).flatMap(Passkey.base64urlDecode),
                  let sig = (body["signature"] as? String).flatMap(Passkey.base64urlDecode),
                  let challenge = store.takeChallenge(for: "auth:" + login) else { return Response(status: .badRequest) }
            let o = origin(request)
            do {
                try Passkey.verifyAssertion(clientDataJSON: cd, authenticatorData: ad, signature: sig, publicKeySPKI: pk,
                                            challenge: challenge, origin: o.origin, rpID: o.rpID)
            } catch {
                return json(["error": "Passkey check failed."], status: .unauthorized)
            }
            var response = json(["ok": true])
            response.headers[.setCookie] = store.sessionCookie(login: login)
            return response
        }

        let sandbox = FileSandbox(roots: ["downloads": Permissions.downloadsURL, "desktop": Permissions.desktopURL,
                                          "documents": Permissions.documentsURL])
        let fileIO = FileIO()

        router.get("files") { request, _ -> Response in
            let q = request.uri.queryParameters
            let root = q.get("root") ?? "downloads"
            if Permissions.folderAllowed(root) != true {
                Permissions.refreshFolderAccess()
                return json(["error": "Tether doesn't have access to this folder yet. On the Mac, click Allow when macOS asks, or turn Tether on in System Settings → Privacy & Security → Files & Folders."], status: .forbidden)
            }
            guard let dir = sandbox.resolve(root: root, relativePath: q.get("path") ?? "") else {
                return Response(status: .badRequest)
            }
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
            guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                          options: [.skipsHiddenFiles]) else {
                return json(["error": "Can't open this folder. On the Mac, allow Tether access to it in System Settings → Privacy & Security → Files & Folders."], status: .forbidden)
            }
            let items: [[String: Any]] = urls.compactMap { url in
                guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                return ["name": url.lastPathComponent, "dir": v.isDirectory ?? false, "size": v.fileSize ?? 0,
                        "mtime": (v.contentModificationDate ?? .distantPast).timeIntervalSince1970]
            }.sorted {
                let ad = $0["dir"] as! Bool, bd = $1["dir"] as! Bool
                if ad != bd { return ad }
                return ($0["mtime"] as! Double) > ($1["mtime"] as! Double)
            }
            return json(["items": items])
        }

        router.get("download") { request, context -> Response in
            let q = request.uri.queryParameters
            guard let url = sandbox.resolve(root: q.get("root") ?? "downloads", relativePath: q.get("path") ?? ""),
                  var isDir = Optional(ObjCBool(false)),
                  FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                return Response(status: .notFound)
            }
            let body = try await fileIO.loadFile(path: url.path, context: context)
            let name = url.lastPathComponent.replacingOccurrences(of: "\"", with: "")
            let encoded = url.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "file"
            return Response(status: .ok, headers: [
                .contentType: "application/octet-stream",
                .contentDisposition: "attachment; filename=\"\(name)\"; filename*=UTF-8''\(encoded)",
            ], body: body)
        }

        router.get("apps") { _, _ -> Response in json(["apps": AppCatalog.list()]) }

        // A small picture of a display, for the Macs picker (also from your other Macs' pages)
        // and the displays overview. At most two a second per login.
        let thumbLimiter = RateLimiter(perSecond: 2)
        router.get("thumbnail") { request, _ -> Response in
            guard thumbLimiter.allow(login(request)) else { return Response(status: .tooManyRequests) }
            let q = request.uri.queryParameters
            let width = min(960, max(160, Int(q.get("w") ?? "") ?? 480))
            guard let jpeg = await Thumbnails.capture(display: q.get("display").flatMap { UInt32($0) }, width: width) else {
                return Response(status: .serviceUnavailable)
            }
            var response = Response(status: .ok, headers: [.contentType: "image/jpeg", .cacheControl: "no-store"],
                                    body: .init(byteBuffer: ByteBuffer(bytes: jpeg)))
            if let origin = request.headers[.origin], let suffix = tailnetSuffix,
               let host = URL(string: origin)?.host, origin.hasPrefix("https://"), host.hasSuffix("." + suffix) {
                response.headers[.accessControlAllowOrigin] = origin
                response.headers[.vary] = "Origin"
            }
            return response
        }

        // Images on the clipboard: the Mac's latest copied image, or one sent from a device.
        router.get("clipboard/image") { request, _ -> Response in
            guard let id = request.uri.queryParameters.get("id").flatMap({ Int($0) }),
                  let png = Hub.shared.clipboardImage(id: id) else { return Response(status: .notFound) }
            return Response(status: .ok, headers: [.contentType: "image/png", .cacheControl: "no-store"],
                            body: .init(byteBuffer: ByteBuffer(bytes: png)))
        }
        router.post("clipboard/image") { request, _ -> Response in
            if Hub.shared.onlyObserving(login: login(request)) {
                return json(["error": "View only is on, so pasting to the Mac is off."], status: .forbidden)
            }
            var body = try await request.body.collect(upTo: 16 << 20)
            guard let data = body.readData(length: body.readableBytes), Hub.shared.setClipboardImage(data) else {
                return json(["error": "That isn't an image the Mac can paste."], status: .badRequest)
            }
            return json(["ok": true])
        }

        router.post("upload") { request, _ -> Response in
            let q = request.uri.queryParameters
            let name = q.get("name") ?? "upload"
            if Hub.shared.onlyObserving(login: login(request)) {
                return json(["error": "View only is on, so uploads are off. Turn off View only to send files."], status: .forbidden)
            }
            // Into the folder being browsed (inside Downloads, Desktop or Documents), else Downloads.
            var folder = Uploads.directory
            var savedRoot = "downloads", savedDir = ""
            if let root = q.get("root") {
                var isDir: ObjCBool = false
                guard Permissions.folderAllowed(root) == true,
                      let dir = sandbox.resolve(root: root, relativePath: q.get("path") ?? ""),
                      FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue
                else { return json(["error": "Can't save into that folder."], status: .forbidden) }
                folder = dir
                savedRoot = root
                savedDir = q.get("path") ?? ""
            }
            let url = Uploads.destination(for: name, in: folder)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                return Response(status: .internalServerError)
            }
            let handle = try FileHandle(forWritingTo: url)
            do {
                for try await chunk in request.body {
                    chunk.withUnsafeReadableBytes { handle.write(Data($0)) }
                }
                try handle.close()
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            NSLog("Tether: saved upload \(url.path)")
            let savedPath = savedDir.isEmpty ? url.lastPathComponent : savedDir + "/" + url.lastPathComponent
            return json(["saved": url.lastPathComponent, "folder": folder.lastPathComponent,
                         "root": savedRoot, "path": savedPath])
        }

        // "Show on Mac": select a file in Finder. Only inside the shared folders, and not in View only.
        router.post("reveal") { request, _ -> Response in
            let q = request.uri.queryParameters
            if Hub.shared.onlyObserving(login: login(request)) {
                return json(["error": "View only is on."], status: .forbidden)
            }
            guard let root = q.get("root"), Permissions.folderAllowed(root) == true,
                  let url = sandbox.resolve(root: root, relativePath: q.get("path") ?? ""),
                  FileManager.default.fileExists(atPath: url.path)
            else { return json(["error": "Can't find that file."], status: .notFound) }
            await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            return json(["ok": true])
        }

        router.ws("ws") { request, _ in
            policy.isAllowed(login: request.headers[tailscaleLoginHeader]) ? .upgrade([:]) : .dontUpgrade
        } onUpgrade: { inbound, outbound, context in
            let login = context.request.headers[tailscaleLoginHeader] ?? "local"
            let device = String((context.request.uri.queryParameters.get("device") ?? "A device").prefix(40))
            let (stream, continuation) = AsyncStream<Outgoing>.makeStream()
            let client = Hub.shared.add(login: login, device: device, continuation: continuation)
            defer { Hub.shared.remove(client) }
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await item in stream {
                        switch item {
                        case .text(let s):
                            try await outbound.write(.text(s))
                        case .video(let buffer):
                            defer { client.videoWritten() }
                            try await outbound.write(.binary(buffer))
                        case .audio(let buffer):
                            try await outbound.write(.binary(buffer))
                        }
                    }
                }
                group.addTask {
                    for try await message in inbound.messages(maxSize: 4 << 20) {
                        if case .text(let text) = message, let parsed = ClientMessage.parse(text) {
                            Hub.shared.handle(parsed, from: client)
                        }
                    }
                }
                _ = try await group.next()
                group.cancelAll()
            }
        }

        let app = Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: router, configuration: .init(ws: .init(maxFrameSize: 1 << 20))),
            configuration: .init(address: .hostname("127.0.0.1", port: port), serverName: "Tether"))
        try await app.runService()
    }

    private static func jsonBody(_ request: Request) async throws -> [String: Any] {
        var req = request
        let buffer = try await req.collectBody(upTo: 64 * 1024)
        return (try? JSONSerialization.jsonObject(with: Data(buffer: buffer)) as? [String: Any]) ?? [:]
    }

    private static func json(_ obj: [String: Any], status: HTTPResponse.Status = .ok) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return Response(status: status, headers: [.contentType: "application/json; charset=utf-8"],
                        body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }
}

enum Uploads {
    static var directory: URL { Permissions.downloadsURL }

    /// A safe, non-clobbering path in ~/Downloads for an uploaded file name.
    static func destination(for rawName: String, in directory: URL = Uploads.directory) -> URL {
        var name = (rawName as NSString).lastPathComponent
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "upload" }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var url = directory.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }
}

private enum SHA256Digest {
    static func of(_ s: String) -> Data { Data(SHA256.hash(data: Data(s.utf8))) }
}

/// A tiny per-key rate limiter (requests per second).
final class RateLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var last: [String: [Date]] = [:]
    private let perSecond: Int
    init(perSecond: Int) { self.perSecond = perSecond }
    func allow(_ key: String) -> Bool {
        lock.withLock {
            let now = Date()
            var recent = (last[key] ?? []).filter { now.timeIntervalSince($0) < 1 }
            guard recent.count < perSecond else { return false }
            recent.append(now)
            last[key] = recent
            return true
        }
    }
}
