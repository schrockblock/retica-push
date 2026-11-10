import Testing
import Foundation
import ReTiCA
@testable import ReTiCAPushCore

/// A packet to `me` whose LXMF source hash is `victim`'s but whose signature is a VALID signature by
/// `forger` over exactly that content (destination + source + payload + hash, as `LXMessage.create`
/// signs it). So a lookup that returns the victim's key fails the signature check, and one that
/// returns the forger's key passes the signature and is stopped only by the hash-equality check.
private func forgedPacket(claiming victim: Identity, signedBy forger: Identity, to me: Identity) -> Data {
    let dest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                           aspects: LXMessage.deliveryAspects, identity: me)!
    let genuine = LXMessage.create(source: forger, destinationHash: dest.hash,
                                   timestamp: 1_700_000_000, title: Data(), content: Data("hi".utf8))
    let headerLength = 2 * LXMessage.destinationLength + LXMessage.signatureLength
    let payload = Data(genuine.packed.dropFirst(headerLength))
    let hashedPart = dest.hash + victim.lxmfDeliveryHash + payload
    let signature = forger.sign(hashedPart + Crypto.fullHash(hashedPart))
    let plaintext = victim.lxmfDeliveryHash + signature + payload
    return try! Packet.data(to: dest, plaintext: plaintext).packed()
}

@Test func pushSenderVerifiesASignedPacket() {
    let me = Identity(), alice = Identity()
    let raw = lxmfPacket(from: alice, to: me)
    let keys = [alice.lxmfDeliveryHash: alice.publicKey]
    #expect(PushSender.verifiedSource(of: raw, identity: me, deliveryHash: me.lxmfDeliveryHash,
                                      publicKeyFor: { keys[$0] }) == alice.lxmfDeliveryHash)
}

@Test func pushSenderVerifiesAPacketEncryptedToAnOwnRatchet() {
    let me = Identity(), alice = Identity()
    let older = SecureRandom.bytes(32)
    let ring = [SecureRandom.bytes(32), older]
    let raw = ratchetLXMFPacket(from: alice, to: me, ratchetPrivate: older)
    let keys = [alice.lxmfDeliveryHash: alice.publicKey]
    #expect(PushSender.verifiedSource(of: raw, identity: me, deliveryHash: me.lxmfDeliveryHash,
                                      ratchets: ring, publicKeyFor: { keys[$0] }) == alice.lxmfDeliveryHash)
    #expect(PushSender.verifiedSource(of: raw, identity: me, deliveryHash: me.lxmfDeliveryHash,
                                      publicKeyFor: { keys[$0] }) == nil)
}

@Test func pushSenderRejectsAForgedSourceHash() {
    let me = Identity(), alice = Identity(), mallory = Identity()
    let raw = forgedPacket(claiming: alice, signedBy: mallory, to: me)
    // The unauthenticated filter is fooled; the verified path is not.
    #expect(BlockedSenderFilter.sourceHash(of: raw, identity: me, deliveryHash: me.lxmfDeliveryHash) == alice.lxmfDeliveryHash)
    #expect(PushSender.verifiedSource(of: raw, identity: me, deliveryHash: me.lxmfDeliveryHash,
                                      publicKeyFor: { _ in alice.publicKey }) == nil)
}

@Test func pushSenderRejectsAKeyForAnotherIdentity() {
    // Mallory claims Alice's hash and signs with her own key; a lookup that hands back Mallory's
    // key for Alice's hash would validate the signature. Only the hash-equality check stops it.
    let me = Identity(), alice = Identity(), mallory = Identity()
    let raw = forgedPacket(claiming: alice, signedBy: mallory, to: me)
    // Sanity: the helper's signature really is valid under Mallory's key.
    let opened = PushSender.openMessage(raw, identity: me, deliveryHash: me.lxmfDeliveryHash)
    #expect(opened?.validateSignature(source: mallory) == true)
    #expect(PushSender.verifiedSource(of: raw, identity: me, deliveryHash: me.lxmfDeliveryHash,
                                      publicKeyFor: { _ in mallory.publicKey }) == nil)
}

@Test func pushSenderRejectsAnUnknownSender() {
    let me = Identity()
    let raw = lxmfPacket(from: Identity(), to: me)
    #expect(PushSender.verifiedSource(of: raw, identity: me, deliveryHash: me.lxmfDeliveryHash,
                                      publicKeyFor: { _ in nil }) == nil)
}

@Test func pushSenderRejectsAnUnparseableKey() {
    let me = Identity()
    let raw = lxmfPacket(from: Identity(), to: me)
    #expect(PushSender.verifiedSource(of: raw, identity: me, deliveryHash: me.lxmfDeliveryHash,
                                      publicKeyFor: { _ in Data(repeating: 1, count: 3) }) == nil)
}

@Test func pushSenderRejectsALinkRequest() throws {
    let me = Identity()
    let linkRequest = try Packet(packetType: .linkRequest, destinationType: .single,
                                 destinationHash: me.lxmfDeliveryHash, payload: Data(repeating: 7, count: 64)).packed()
    #expect(PushSender.verifiedSource(of: linkRequest, identity: me, deliveryHash: me.lxmfDeliveryHash,
                                      publicKeyFor: { _ in Identity().publicKey }) == nil)
}

@Test func pushSenderOpenMessageMatchesTheFilter() {
    let me = Identity(), alice = Identity()
    let raw = lxmfPacket(from: alice, to: me)
    #expect(PushSender.openMessage(raw, identity: me, deliveryHash: me.lxmfDeliveryHash)?.sourceHash
            == alice.lxmfDeliveryHash)
    #expect(PushSender.openMessage(raw, identity: me, deliveryHash: Identity().lxmfDeliveryHash) == nil)
}
