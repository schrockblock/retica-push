import Foundation
import ReTiCA

/// The registration request of docs/server-contract.md §1, before signing.
public struct PushRegistration: Equatable, Sendable {
    public enum Domain: String, Sendable {
        case register = "retica-push-register-v1"
        case unregister = "retica-push-unregister-v1"
    }

    public enum Environment: String, Sendable, Codable {
        case production
        case sandbox
    }

    public static let version = 1

    public var publicKey: Data
    public var pushToken: Data
    public var platform: String
    public var environment: Environment
    public var bundleID: String
    public var issuedAt: UInt64

    public init(publicKey: Data, pushToken: Data, platform: String = "ios",
                environment: Environment, bundleID: String, issuedAt: UInt64) {
        self.publicKey = publicKey
        self.pushToken = pushToken
        self.platform = platform
        self.environment = environment
        self.bundleID = bundleID
        self.issuedAt = issuedAt
    }

    /// Contract §1.2. nil when a field cannot be length-prefixed (token > 65535 bytes, or a
    /// string field > 255 UTF-8 bytes) or the key is not 64 bytes.
    public func signingBytes(domain: Domain) -> Data? {
        guard publicKey.count == Identity.keySize, pushToken.count <= Int(UInt16.max) else { return nil }
        let platformBytes = Data(platform.utf8)
        let environmentBytes = Data(environment.rawValue.utf8)
        let bundleBytes = Data(bundleID.utf8)
        for field in [platformBytes, environmentBytes, bundleBytes] where field.count > Int(UInt8.max) {
            return nil
        }
        var out = Data(domain.rawValue.utf8)
        out.append(publicKey)
        out.append(UInt8(pushToken.count >> 8))
        out.append(UInt8(pushToken.count & 0xFF))
        out.append(pushToken)
        out.append(UInt8(platformBytes.count))
        out.append(platformBytes)
        out.append(UInt8(environmentBytes.count))
        out.append(environmentBytes)
        out.append(UInt8(bundleBytes.count))
        out.append(bundleBytes)
        for shift in stride(from: 56, through: 0, by: -8) {
            out.append(UInt8((issuedAt >> UInt64(shift)) & 0xFF))
        }
        return out
    }

    /// nil when the layout is invalid (see `signingBytes`) or `identity` has no private key.
    public func signed(with identity: Identity, domain: Domain) -> SignedRegistration? {
        guard identity.privateKey != nil, let bytes = signingBytes(domain: domain) else { return nil }
        return SignedRegistration(registration: self, domain: domain, signature: identity.sign(bytes))
    }
}

/// A registration plus the Ed25519 signature over its signing bytes. `domain` is remembered so
/// `verify()` can rebuild the bytes; it is not part of the JSON (the HTTP method carries it).
public struct SignedRegistration: Equatable, Sendable {
    public var registration: PushRegistration
    public var domain: PushRegistration.Domain
    public var signature: Data

    public init(registration: PushRegistration, domain: PushRegistration.Domain, signature: Data) {
        self.registration = registration
        self.domain = domain
        self.signature = signature
    }

    /// Server-side check, reproduced here so tests and the host app can assert what they send.
    public func verify() -> Bool {
        guard let identity = Identity(publicKey: registration.publicKey),
              let bytes = registration.signingBytes(domain: domain)
        else { return false }
        return identity.validate(signature: signature, message: bytes)
    }

    public enum JSONError: Error, Equatable {
        case malformed
    }

    /// Contract §1.1. Keys in a stable order, bytes base64, the token hex.
    public func jsonData() throws -> Data {
        let object: [String: Any] = [
            "v": PushRegistration.version,
            "identity_public_key": registration.publicKey.base64EncodedString(),
            "push_token": registration.pushToken.hexString,
            "platform": registration.platform,
            "environment": registration.environment.rawValue,
            "bundle_id": registration.bundleID,
            "issued_at": registration.issuedAt,
            "signature": signature.base64EncodedString(),
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    public static func fromJSON(_ data: Data, domain: PushRegistration.Domain) throws -> SignedRegistration {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["v"] as? Int == PushRegistration.version,
              let keyString = object["identity_public_key"] as? String,
              let publicKey = Data(base64Encoded: keyString),
              let tokenHex = object["push_token"] as? String,
              let pushToken = Data(hexString: tokenHex),
              let platform = object["platform"] as? String,
              let environmentString = object["environment"] as? String,
              let environment = PushRegistration.Environment(rawValue: environmentString),
              let bundleID = object["bundle_id"] as? String,
              let issuedAt = object["issued_at"] as? UInt64,
              let signatureString = object["signature"] as? String,
              let signature = Data(base64Encoded: signatureString)
        else { throw JSONError.malformed }
        let registration = PushRegistration(publicKey: publicKey, pushToken: pushToken, platform: platform,
                                            environment: environment, bundleID: bundleID, issuedAt: issuedAt)
        return SignedRegistration(registration: registration, domain: domain, signature: signature)
    }
}
