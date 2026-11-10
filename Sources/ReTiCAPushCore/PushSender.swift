import Foundation
import ReTiCA

/// Who sent a pushed packet, VERIFIED. Unlike `BlockedSenderFilter`, which reads the source hash
/// unauthenticated and is safe only for suppression, `verifiedSource` checks the sender's
/// signature, so the result is safe to show as a name and face. The extension has no network and
/// no announce table, so the caller supplies keys it already trusts through `publicKeyFor`
/// (sender lxmf.delivery hash to that sender's public key, or nil if unknown).
public enum PushSender {
    /// The LXMF message inside a pushed packet, still unauthenticated. Same checks as
    /// `BlockedSenderFilter` always made: a private key is present, no IFAC flag, a DATA/SINGLE
    /// packet to `deliveryHash`, payload opened with `ratchets` then the identity's static key
    /// (see `BlockedSenderFilter` for the ring), then unpacked as `LXMFRouter.received` does for a
    /// single packet. Link-based sends and LINKREQUEST pushes return nil.
    public static func openMessage(_ raw: Data, identity: Identity, deliveryHash: Data,
                                   ratchets: [Data]? = nil) -> LXMessage? {
        guard identity.privateKey != nil else { return nil }
        guard let first = raw.first, first & 0x80 == 0 else { return nil }
        guard let packet = Packet(raw: raw) else { return nil }
        guard packet.packetType == .data,
              packet.destinationType == .single,
              packet.destinationHash == deliveryHash
        else { return nil }
        guard let plaintext = identity.decrypt(packet.payload, ratchets: ratchets) else { return nil }
        return LXMessage.fromOpportunistic(destinationHash: packet.destinationHash, payload: plaintext)
    }

    /// The sender's lxmf.delivery hash, only if the packet opens, `publicKeyFor` knows the sender,
    /// that key's own delivery hash equals the claimed source hash, and the message signature
    /// validates under it. Otherwise nil.
    public static func verifiedSource(of raw: Data, identity: Identity, deliveryHash: Data,
                                      ratchets: [Data]? = nil,
                                      publicKeyFor: (Data) -> Data?) -> Data? {
        guard let message = openMessage(raw, identity: identity, deliveryHash: deliveryHash,
                                        ratchets: ratchets),
              let key = publicKeyFor(message.sourceHash),
              let sender = Identity(publicKey: key),
              LXMessage.deliveryHash(identityHash: sender.hash) == message.sourceHash,
              message.validateSignature(source: sender)
        else { return nil }
        return message.sourceHash
    }
}
