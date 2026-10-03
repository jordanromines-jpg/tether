import CryptoKit
import Foundation

/// WebAuthn (passkey) verification for Tether's optional second lock.
/// Registration stores the credential's SPKI public key (from `response.getPublicKey()`,
/// so no CBOR/COSE parsing is needed); assertions are verified with P-256 ECDSA (alg -7).
public enum Passkey {
    public enum Failure: Error, Equatable {
        case badClientData, wrongType, wrongChallenge, wrongOrigin, wrongRelyingParty
        case userNotPresent, userNotVerified, badSignature, badKey
    }

    public static func base64urlDecode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }

    public static func base64urlEncode(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Checks clientDataJSON: type, challenge (base64url of what we issued) and origin.
    public static func checkClientData(_ json: Data, type: String, challenge: Data, origin: String) throws {
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw Failure.badClientData }
        guard obj["type"] as? String == type else { throw Failure.wrongType }
        guard let c = obj["challenge"] as? String, base64urlDecode(c) == challenge else { throw Failure.wrongChallenge }
        guard obj["origin"] as? String == origin else { throw Failure.wrongOrigin }
    }

    /// Validates a registration: the browser's clientData must match, and the key must be a P-256 SPKI.
    public static func verifyRegistration(clientDataJSON: Data, publicKeySPKI: Data, challenge: Data, origin: String) throws {
        try checkClientData(clientDataJSON, type: "webauthn.create", challenge: challenge, origin: origin)
        guard (try? P256.Signing.PublicKey(derRepresentation: publicKeySPKI)) != nil else { throw Failure.badKey }
    }

    /// Verifies a sign-in assertion against a stored public key.
    public static func verifyAssertion(clientDataJSON: Data, authenticatorData: Data, signature: Data,
                                       publicKeySPKI: Data, challenge: Data, origin: String, rpID: String) throws {
        try checkClientData(clientDataJSON, type: "webauthn.get", challenge: challenge, origin: origin)
        guard authenticatorData.count >= 37 else { throw Failure.wrongRelyingParty }
        let rpHash = Data(SHA256.hash(data: Data(rpID.utf8)))
        guard authenticatorData.prefix(32) == rpHash else { throw Failure.wrongRelyingParty }
        let flags = authenticatorData[authenticatorData.startIndex + 32]
        guard flags & 0x01 != 0 else { throw Failure.userNotPresent }
        guard flags & 0x04 != 0 else { throw Failure.userNotVerified }
        guard let key = try? P256.Signing.PublicKey(derRepresentation: publicKeySPKI) else { throw Failure.badKey }
        guard let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { throw Failure.badSignature }
        let signed = authenticatorData + Data(SHA256.hash(data: clientDataJSON))
        guard key.isValidSignature(sig, for: signed) else { throw Failure.badSignature }
    }
}

/// Signed session cookie value: "<login>|<expiry unix>|<hmac>".
public struct SessionToken {
    public let key: SymmetricKey
    public init(secret: Data) { key = SymmetricKey(data: secret) }

    public func issue(login: String, expires: Date) -> String {
        let body = "\(login.lowercased())|\(Int(expires.timeIntervalSince1970))"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(body.utf8), using: key)
        return body + "|" + Passkey.base64urlEncode(Data(mac))
    }

    /// True if the token is authentic, unexpired and belongs to `login`.
    public func isValid(_ token: String, login: String, now: Date = Date()) -> Bool {
        let parts = token.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == login.lowercased(), let exp = Double(parts[1]),
              exp > now.timeIntervalSince1970, let mac = Passkey.base64urlDecode(parts[2]) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: Data("\(parts[0])|\(parts[1])".utf8), using: key)
    }
}
