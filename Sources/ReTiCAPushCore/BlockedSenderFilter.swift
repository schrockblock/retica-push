import Foundation
import ReTiCA

/// Who sent a pushed packet, for banner suppression only (spec 2026-10-15 §4). Same packet
/// checks as `ProofBuilder.proof`, then the payload is opened with the identity's static key
/// (ReTiCA has no own-ratchet lifecycle, so senders encrypt to it) and unpacked the way
/// `LXMFRouter.received` does for a single packet. The result is the sender's lxmf.delivery
/// hash, what `LXMessage.sourceHash` carries and what the host's blocklist holds.
///
/// Unauthenticated: nothing here checks the signature, so a forged source hash could suppress
/// a banner. It can do nothing else. Link-based sends and LINKREQUEST pushes cannot be
/// attributed at all and return nil, so a blocked sender who uses links still gets the generic
/// banner.
public enum BlockedSenderFilter {
    public static func sourceHash(of raw: Data, identity: Identity, deliveryHash: Data) -> Data? {
        guard identity.privateKey != nil else { return nil }
        guard let first = raw.first, first & 0x80 == 0 else { return nil }
        guard let packet = Packet(raw: raw) else { return nil }
        guard packet.packetType == .data,
              packet.destinationType == .single,
              packet.destinationHash == deliveryHash
        else { return nil }
        guard let plaintext = identity.decrypt(packet.payload) else { return nil }
        guard let message = LXMessage.fromOpportunistic(destinationHash: packet.destinationHash,
                                                        payload: plaintext)
        else { return nil }
        return message.sourceHash
    }
}
