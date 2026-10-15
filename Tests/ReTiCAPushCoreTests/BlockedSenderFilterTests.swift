import Testing
import Foundation
import ReTiCA
@testable import ReTiCAPushCore

/// A HEADER_1 DATA packet carrying an opportunistic LXMF message from `sender`, encrypted to
/// `me`'s lxmf.delivery destination, exactly what a push hub forwards.
func lxmfPacket(from sender: Identity, to me: Identity, content: String = "hi") -> Data {
    let dest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                           aspects: LXMessage.deliveryAspects, identity: me)!
    let message = LXMessage.create(source: sender, destinationHash: dest.hash,
                                   timestamp: 1_700_000_000, title: Data(), content: Data(content.utf8))
    return try! Packet.data(to: dest, plaintext: message.opportunisticPayload).packed()
}

/// A DATA packet to `me` whose plaintext is not an LXMF frame.
func plainPacket(to me: Identity) -> Data {
    let dest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                           aspects: LXMessage.deliveryAspects, identity: me)!
    return try! Packet.data(to: dest, plaintext: Data("hi".utf8)).packed()
}

@Test func blockedSenderFilterAttributesAnOpportunisticLXMFPacket() {
    let me = Identity()
    let sender = Identity()
    let raw = lxmfPacket(from: sender, to: me)
    let hash = BlockedSenderFilter.sourceHash(of: raw, identity: me, deliveryHash: me.lxmfDeliveryHash)
    #expect(hash == sender.lxmfDeliveryHash)
    #expect(hash != sender.hash)
}

@Test func blockedSenderFilterReturnsNilForAPacketToAnotherDestination() {
    // Encrypted to `me` (so it WOULD decrypt) but the caller says our delivery hash is another
    // one: the destination check alone must refuse it.
    let me = Identity()
    let other = Identity()
    let raw = lxmfPacket(from: Identity(), to: me)
    #expect(BlockedSenderFilter.sourceHash(of: raw, identity: me, deliveryHash: other.lxmfDeliveryHash) == nil)
}

@Test func blockedSenderFilterReturnsNilForANonLXMFPlaintext() {
    let me = Identity()
    let raw = plainPacket(to: me)
    #expect(BlockedSenderFilter.sourceHash(of: raw, identity: me, deliveryHash: me.lxmfDeliveryHash) == nil)
}

@Test func blockedSenderFilterReturnsNilForANonDataPacket() throws {
    let me = Identity()
    let announce = try Packet(packetType: .announce, destinationType: .single,
                              destinationHash: me.lxmfDeliveryHash, payload: Data(repeating: 1, count: 40)).packed()
    #expect(BlockedSenderFilter.sourceHash(of: announce, identity: me, deliveryHash: me.lxmfDeliveryHash) == nil)
}

@Test func blockedSenderFilterReturnsNilForAnIFACFlaggedPacket() {
    let me = Identity()
    var flagged = lxmfPacket(from: Identity(), to: me)
    flagged[0] |= 0x80
    #expect(BlockedSenderFilter.sourceHash(of: flagged, identity: me, deliveryHash: me.lxmfDeliveryHash) == nil)
}

@Test func blockedSenderFilterReturnsNilForGarbage() {
    let me = Identity()
    #expect(BlockedSenderFilter.sourceHash(of: Data([0x00, 0x01, 0x02]), identity: me,
                                           deliveryHash: me.lxmfDeliveryHash) == nil)
    #expect(BlockedSenderFilter.sourceHash(of: Data(), identity: me, deliveryHash: me.lxmfDeliveryHash) == nil)
}

@Test func blockedSenderFilterReturnsNilWithoutAPrivateKey() {
    let me = Identity()
    let publicOnly = Identity(publicKey: me.publicKey)!
    let raw = lxmfPacket(from: Identity(), to: me)
    #expect(BlockedSenderFilter.sourceHash(of: raw, identity: publicOnly, deliveryHash: me.lxmfDeliveryHash) == nil)
}

@Test func blockedSenderFilterReturnsNilForARatchetEncryptedPacket() {
    // A sender that encrypts to a ratchet we never had: the static key cannot open it.
    let me = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                           aspects: LXMessage.deliveryAspects, identity: me)!
    let message = LXMessage.create(source: Identity(), destinationHash: dest.hash,
                                   timestamp: 1_700_000_000, title: Data(), content: Data("hi".utf8))
    let ratchet = Identity().publicKey.prefix(32)   // any 32-byte X25519 public key
    let raw = try! Packet.data(to: dest, plaintext: message.opportunisticPayload, ratchet: Data(ratchet)).packed()
    #expect(BlockedSenderFilter.sourceHash(of: raw, identity: me, deliveryHash: me.lxmfDeliveryHash) == nil)
}

@Test func blockedSenderFilterReturnsNilForALinkRequestPacket() throws {
    let me = Identity()
    let linkRequest = try Packet(packetType: .linkRequest, destinationType: .single,
                                 destinationHash: me.lxmfDeliveryHash, payload: Data(repeating: 7, count: 64)).packed()
    #expect(BlockedSenderFilter.sourceHash(of: linkRequest, identity: me, deliveryHash: me.lxmfDeliveryHash) == nil)
}
