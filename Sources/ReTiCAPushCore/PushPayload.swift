import Foundation
import ReTiCA

/// The `rns` block of a push from a ReTiCA push hub (docs/server-contract.md §3): a version and a
/// list of base64 raw Reticulum packets. Pure and synchronous, so the service extension can call
/// it before anything crosses an actor boundary (`[AnyHashable: Any]` is not Sendable).
public enum PushPayload {
    public static let version = 1
    public static let maxPackets = 8

    public enum DecodeError: Error, Equatable {
        case missingBlock
        case unsupportedVersion
        case notAnArray
        case tooManyPackets
        /// The entry at this index is not a string, not base64, or decodes to zero bytes.
        case invalidEntry(Int)
        /// The entry at this index decodes to more than `Packet.mtu` bytes.
        case oversizeEntry(Int)
    }

    /// True for the hub's "messages waiting on the propagation node" alert: `rns.kind` is
    /// `"propagated"` and `packets` is empty, so the app syncs instead of decoding anything.
    public static func isPropagated(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let block = userInfo["rns"] as? [String: Any] else { return false }
        return block["v"] as? Int == version && block["kind"] as? String == "propagated"
    }

    public static func decode(_ userInfo: [AnyHashable: Any]) throws -> [Data] {
        guard let block = userInfo["rns"] as? [String: Any] else { throw DecodeError.missingBlock }
        guard let v = block["v"] as? Int, v == version else { throw DecodeError.unsupportedVersion }
        guard let entries = block["packets"] as? [Any] else { throw DecodeError.notAnArray }
        guard entries.count <= maxPackets else { throw DecodeError.tooManyPackets }
        return try entries.enumerated().map { index, entry in
            guard let string = entry as? String,
                  let raw = Data(base64Encoded: string),
                  !raw.isEmpty
            else { throw DecodeError.invalidEntry(index) }
            guard raw.count <= Packet.mtu else { throw DecodeError.oversizeEntry(index) }
            return raw
        }
    }
}
