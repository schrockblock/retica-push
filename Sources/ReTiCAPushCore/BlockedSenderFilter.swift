import Foundation
import ReTiCA

/// Who sent a pushed packet, for banner suppression only (spec 2026-10-15 §4). Same packet
/// checks as `ProofBuilder.proof`, then the payload is opened and unpacked the way
/// `LXMFRouter.received` does for a single packet. The result is the sender's lxmf.delivery
/// hash, what `LXMessage.sourceHash` carries and what the host's blocklist holds.
///
/// A host that enables its own ratchets (ReTiCA's `.enableRatchets`) announces a ratchet, and
/// ratchet-aware senders then encrypt to it, not to the identity key. Such a host passes its
/// saved ring as `ratchets`: each is tried first, then the identity key, as
/// `Identity.decrypt(_:ratchets:)` does. Without the ring those packets cannot be attributed
/// and return nil, which vetoes suppression (fails open: the banner shows). With a full ring
/// (512 keys) one packet costs up to 513 key agreements.
///
/// Unauthenticated: nothing here checks the signature, so a forged source hash could suppress
/// a banner. It can do nothing else. Link-based sends and LINKREQUEST pushes cannot be
/// attributed at all and return nil, so a blocked sender who uses links still gets the generic
/// banner.
public enum BlockedSenderFilter {
    public static func sourceHash(of raw: Data, identity: Identity, deliveryHash: Data,
                                  ratchets: [Data]? = nil) -> Data? {
        guard identity.privateKey != nil else { return nil }
        guard let first = raw.first, first & 0x80 == 0 else { return nil }
        guard let packet = Packet(raw: raw) else { return nil }
        guard packet.packetType == .data,
              packet.destinationType == .single,
              packet.destinationHash == deliveryHash
        else { return nil }
        guard let plaintext = identity.decrypt(packet.payload, ratchets: ratchets) else { return nil }
        guard let message = LXMessage.fromOpportunistic(destinationHash: packet.destinationHash,
                                                        payload: plaintext)
        else { return nil }
        return message.sourceHash
    }
}
