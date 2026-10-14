import Foundation
import ReTiCA

/// The APNs environment a registration names (docs/server-contract.md §1.2).
public enum PushEnvironment: String, Sendable, Codable, Equatable {
    case production
    case sandbox
}

/// msgpack bodies of the hub's `/register` and `/unregister` link requests and their responses
/// (docs/server-contract.md §1.2). Pure.
public enum RegistrationWire {
    public static let version: UInt64 = 1
    public static let registerPath = "/register"
    public static let unregisterPath = "/unregister"

    public enum Response: Equatable, Sendable {
        case registered(destinationHash: Data, expiresAt: Int64)
        case unregistered
        case refused(code: String)
        case malformed
    }

    public static let defaultAspects = ["lxmf", "delivery"]

    public static func registerRequest(token: Data, environment: PushEnvironment, bundleID: String,
                                       aspects: [String]? = nil) -> Data {
        var pairs: [MsgPackValue.Pair] = [
            .init("v", .uint(version)),
            .init("token", .bin(token)),
            .init("environment", .string(environment.rawValue)),
            .init("bundle_id", .string(bundleID)),
        ]
        appendAspects(aspects, to: &pairs)
        return MsgPack.encode(.map(pairs))
    }

    public static func unregisterRequest(aspects: [String]? = nil) -> Data {
        var pairs: [MsgPackValue.Pair] = [.init("v", .uint(version))]
        appendAspects(aspects, to: &pairs)
        return MsgPack.encode(.map(pairs))
    }

    /// The hub assumes `lxmf.delivery` when the key is absent, so the default stays off the wire.
    private static func appendAspects(_ aspects: [String]?, to pairs: inout [MsgPackValue.Pair]) {
        if let aspects, aspects != defaultAspects {
            pairs.append(.init("aspects", .array(aspects.map { .string($0) })))
        }
    }

    /// `{"ok": true, "destination_hash", "expires_at"}` → registered; `{"ok": true}` → unregistered;
    /// `{"ok": false, "error"}` → refused; anything else → malformed.
    public static func decodeResponse(_ data: Data) -> Response {
        guard case let .map(pairs)? = MsgPack.decodeValue(data) else { return .malformed }
        var fields: [String: MsgPackValue] = [:]
        for pair in pairs where fields[pair.key] == nil { fields[pair.key] = pair.value }
        guard case let .bool(ok)? = fields["ok"] else { return .malformed }
        if !ok {
            guard case let .string(code)? = fields["error"] else { return .malformed }
            return .refused(code: code)
        }
        switch (fields["destination_hash"], fields["expires_at"]) {
        case let (.bin(hash)?, expires?):
            guard hash.count == 16, let expiresAt = int64(expires) else { return .malformed }
            return .registered(destinationHash: hash, expiresAt: expiresAt)
        case (nil, nil):
            return .unregistered
        default:
            return .malformed
        }
    }

    private static func int64(_ value: MsgPackValue) -> Int64? {
        switch value {
        case let .uint(u): Int64(exactly: u)
        case let .int(i): i
        default: nil
        }
    }
}
