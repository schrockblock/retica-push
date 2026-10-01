import Foundation
import ReTiCA

/// Builds the proof the service extension sends for a pushed packet, exactly as
/// `Transport.proveSingle` would (Transport.swift:1083-1090): an unencrypted HEADER_1 PROOF to
/// the packet's proof destination (`packetHash[:16]`), carrying the 64-byte implicit proof
/// `identity.sign(packetHash)`, HDLC-framed for the hub's TCP interface.
public enum ProofBuilder {
    /// nil unless `raw` is an unflagged, parseable, single-destination DATA packet addressed to
    /// `deliveryHash` and `identity` can sign. Nothing is decrypted.
    public static func proof(for raw: Data, identity: Identity, deliveryHash: Data) -> Data? {
        guard identity.privateKey != nil else { return nil }
        // An IFAC-flagged packet needs the interface key to unmask. We have none, so the app
        // proves it on drain instead (spec §1).
        guard let first = raw.first, first & 0x80 == 0 else { return nil }
        guard let packet = Packet(raw: raw) else { return nil }
        guard packet.packetType == .data,
              packet.destinationType == .single,
              packet.destinationHash == deliveryHash
        else { return nil }
        let packetHash = packet.packetHash
        let proof = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                           destinationType: .single, context: .none, contextFlag: false, hops: 0,
                           destinationHash: Data(packetHash.prefix(Packet.addressLength)),
                           transportId: nil, payload: identity.sign(packetHash))
        guard let packed = try? proof.packed() else { return nil }
        return HDLC.frame(packed)
    }
}
