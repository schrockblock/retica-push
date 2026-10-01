import Testing
import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCAInterfaces
import ReTiCATransport
import ReTiCANode
@testable import ReTiCAPushCore

private let ifID = InterfaceID("tcp-hub")

/// A HEADER_1 DATA packet encrypted to `me`'s lxmf.delivery destination.
private func dataPacket(to me: Identity, plaintext: String = "hello") -> (raw: Data, hash: Data) {
    let dest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                           aspects: LXMessage.deliveryAspects, identity: me)!
    let packet = Packet.data(to: dest, plaintext: Data(plaintext.utf8))
    return (try! packet.packed(), packet.packetHash)
}

private func deframe(_ framed: Data) -> Data? {
    var deframer = HDLCDeframer()
    return deframer.ingest(framed).first
}

@Test func proofBuilderProvesADataPacketToOurDeliveryHash() throws {
    let me = Identity()
    let (raw, hash) = dataPacket(to: me)
    let framed = try #require(ProofBuilder.proof(for: raw, identity: me, deliveryHash: me.lxmfDeliveryHash))
    let deframed = try #require(deframe(framed))
    let proof = try #require(Packet(raw: deframed))
    #expect(proof.packetType == .proof)
    #expect(proof.destinationType == .single)
    #expect(proof.destinationHash == hash.prefix(16))
    #expect(proof.payload.count == 64)
    #expect(me.validate(signature: proof.payload, message: hash))
}

@Test @MainActor func proofBuilderProofConfirmsASenderReceiptInTransport() async throws {
    // Pins the builder to ReTiCA's real validator: a sender holding a receipt for this packet
    // must see `singlePacketDelivered` when our proof arrives.
    let me = Identity()
    let (raw, hash) = dataPacket(to: me)
    let token = Data("message-hash".utf8)
    var initial = Transport.State()
    initial.interfaces[ifID] = .default
    initial.pendingReceipts[Data(hash.prefix(16))] = Transport.State.PendingReceipt(
        packetHash: hash, token: token, identity: Identity(publicKey: me.publicKey)!,
        expiresAt: .distantFuture)
    let store = TestStore(initialState: initial) { Transport() }
    let framed = try #require(ProofBuilder.proof(for: raw, identity: me, deliveryHash: me.lxmfDeliveryHash))
    let frame = try #require(deframe(framed))
    await store.send(.received(ifID, frame)) { $0.pendingReceipts = [:] }
    await store.receive(.delegate(.singlePacketDelivered(token: token)))
}

@Test func proofBuilderIgnoresAPacketForAnotherDestination() {
    let me = Identity()
    let (raw, _) = dataPacket(to: Identity())
    #expect(ProofBuilder.proof(for: raw, identity: me, deliveryHash: me.lxmfDeliveryHash) == nil)
}

@Test func proofBuilderIgnoresANonDataPacket() throws {
    let me = Identity()
    let announce = Packet(packetType: .announce, destinationType: .single,
                          destinationHash: me.lxmfDeliveryHash, payload: Data(repeating: 1, count: 40))
    #expect(ProofBuilder.proof(for: try announce.packed(), identity: me, deliveryHash: me.lxmfDeliveryHash) == nil)
}

@Test func proofBuilderIgnoresAnIFACFlaggedPacket() {
    let me = Identity()
    var (raw, _) = dataPacket(to: me)
    raw[0] |= 0x80
    #expect(ProofBuilder.proof(for: raw, identity: me, deliveryHash: me.lxmfDeliveryHash) == nil)
}

@Test func proofBuilderIgnoresGarbage() {
    let me = Identity()
    #expect(ProofBuilder.proof(for: Data([0x00]), identity: me, deliveryHash: me.lxmfDeliveryHash) == nil)
}

@Test func proofBuilderNeedsAPrivateKey() {
    let me = Identity()
    let (raw, _) = dataPacket(to: me)
    let publicOnly = Identity(publicKey: me.publicKey)!
    #expect(ProofBuilder.proof(for: raw, identity: publicOnly, deliveryHash: me.lxmfDeliveryHash) == nil)
}

@Test @MainActor func deliveryHashMatchesWhatReTiCARegisters() async throws {
    let me = Identity()
    let store = TestStore(
        initialState: LXMFNode.State(identity: me, endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    ) {
        LXMFNode()
    } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    await store.send(.registerDelivery)
    await store.skipReceivedActions(strict: false)
    #expect(try #require(store.state.deliveryDestinationHash) == me.lxmfDeliveryHash)
}
