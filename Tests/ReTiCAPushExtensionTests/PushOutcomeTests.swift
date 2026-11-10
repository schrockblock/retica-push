import Testing
import Foundation
import ReTiCA
import ReTiCAPushCore
@testable import ReTiCAPushExtension

private func freshDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "ReTiCAPushOutcomeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

/// A pushed opportunistic LXMF packet from `sender` to `me`.
private func lxmfPacket(from sender: Identity, to me: Identity) -> Data {
    let dest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                           aspects: LXMessage.deliveryAspects, identity: me)!
    let message = LXMessage.create(source: sender, destinationHash: dest.hash,
                                   timestamp: 1_700_000_000, title: Data(), content: Data("hi".utf8))
    return try! Packet.data(to: dest, plaintext: message.opportunisticPayload).packed()
}

/// A DATA packet to `me` that is not an LXMF frame (cannot be attributed).
private func plainPacket(to me: Identity) -> Data {
    let dest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                           aspects: LXMessage.deliveryAspects, identity: me)!
    return try! Packet.data(to: dest, plaintext: Data("hi".utf8)).packed()
}

/// A pushed packet from `sender` encrypted to the ratchet whose private key is `ratchetPrivate`.
private func ratchetPacket(from sender: Identity, to me: Identity, ratchetPrivate: Data) -> Data {
    let dest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                           aspects: LXMessage.deliveryAspects, identity: me)!
    let message = LXMessage.create(source: sender, destinationHash: dest.hash,
                                   timestamp: 1_700_000_000, title: Data(), content: Data("hi".utf8))
    let ratchet = Identity.ratchetPublicKey(privateKey: ratchetPrivate)!
    return try! Packet.data(to: dest, plaintext: message.opportunisticPayload, ratchet: ratchet).packed()
}

/// A packet that claims `victim` as its source but carries a VALID signature by `forger` over the
/// victim's source hash (destination + source + payload + hash, as `LXMessage.create` signs it).
/// A lookup that returns the victim's key fails the signature check, and one that returns the
/// forger's key passes it and is stopped only by the hash-equality check.
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

private func userInfo(_ packets: [Data]) -> [AnyHashable: Any] {
    ["aps": ["alert": ["title": "New message"]],
     "rns": ["v": 1, "packets": packets.map { $0.base64EncodedString() }]]
}

private func directory(_ pairs: KeyValuePairs<Identity, String>) -> SenderDirectory {
    var entries: [String: SenderDirectory.Entry] = [:]
    for (id, name) in pairs {
        entries[id.lxmfDeliveryHash.pushHex] = .init(name: name, publicKey: id.publicKey, imageFile: nil)
    }
    return SenderDirectory(entries: entries)
}

private let settings = SharedPushSettings(hubHost: "hub.example.net", hubPort: 4242,
                                          keychainService: "reticulum.identity", keychainAccessGroup: "TEAM.g")

private func handler(identity: Identity?, blocked: Set<String>, senders: SenderDirectory,
                     loadRatchets: @escaping @Sendable (Data) -> [Data]? = { _ in nil }) -> PushServiceHandler {
    PushServiceHandler(inbox: PushInbox(directory: freshDirectory()), settings: settings,
                       blockedSenders: blocked, senders: senders,
                       loadIdentity: { identity }, loadRatchets: loadRatchets,
                       sendFrames: { _, _, _ in })
}

/// An 8 s uncancellable `sendFrames` against a 200 ms deadline.
private func slowHandler(identity: Identity, senders: SenderDirectory) -> PushServiceHandler {
    PushServiceHandler(inbox: PushInbox(directory: freshDirectory()), settings: settings,
                       senders: senders, loadIdentity: { identity },
                       sendFrames: { _, _, _ in
                           await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                               DispatchQueue.global().asyncAfter(deadline: .now() + 8) { continuation.resume() }
                           }
                       },
                       deadline: .milliseconds(200))
}

@Test func pushOutcomeNamesASenderWithAnEmptyBlocklist() async {
    let me = Identity(), alice = Identity()
    let out = await handler(identity: me, blocked: [], senders: directory([alice: "Alice"]))
        .outcome(userInfo: userInfo([lxmfPacket(from: alice, to: me), lxmfPacket(from: alice, to: me)]))
    #expect(out.verdict == .deliverOriginal)
    #expect(out.sender?.hex == alice.lxmfDeliveryHash.pushHex)
    #expect(out.sender?.entry.name == "Alice")
}

@Test func pushOutcomeNamesASenderWhoEncryptedToAnOwnRatchet() async {
    let me = Identity(), alice = Identity()
    let ratchetPrivate = SecureRandom.bytes(32)
    let raw = ratchetPacket(from: alice, to: me, ratchetPrivate: ratchetPrivate)
    let out = await handler(identity: me, blocked: [], senders: directory([alice: "Alice"]),
                            loadRatchets: { _ in [ratchetPrivate] })
        .outcome(userInfo: userInfo([raw]))
    #expect(out.sender?.hex == alice.lxmfDeliveryHash.pushHex)
    #expect(out.sender?.entry.name == "Alice")
}

@Test func pushOutcomeNamesNobodyForTwoSenders() async {
    let me = Identity(), alice = Identity(), bob = Identity()
    let out = await handler(identity: me, blocked: [], senders: directory([alice: "Alice", bob: "Bob"]))
        .outcome(userInfo: userInfo([lxmfPacket(from: alice, to: me), lxmfPacket(from: bob, to: me)]))
    #expect(out.sender == nil)
}

@Test func pushOutcomeNamesNobodyWhenAnUnattributablePacketRidesAlong() async {
    let me = Identity(), alice = Identity()
    let out = await handler(identity: me, blocked: [], senders: directory([alice: "Alice"]))
        .outcome(userInfo: userInfo([lxmfPacket(from: alice, to: me), plainPacket(to: me)]))
    #expect(out.sender == nil)
}

@Test func pushOutcomeNamesNobodyForAForgery() async {
    let me = Identity(), alice = Identity(), mallory = Identity()
    let out = await handler(identity: me, blocked: [], senders: directory([alice: "Alice"]))
        .outcome(userInfo: userInfo([forgedPacket(claiming: alice, signedBy: mallory, to: me)]))
    #expect(out.sender == nil)
}

@Test func pushOutcomeDropsTheSenderWhenSuppressed() async {
    let me = Identity(), blocked = Identity()
    let out = await handler(identity: me, blocked: [blocked.lxmfDeliveryHash.pushHex],
                            senders: directory([blocked: "B"]))
        .outcome(userInfo: userInfo([lxmfPacket(from: blocked, to: me)]))
    #expect(out.verdict == .suppress)
    #expect(out.sender == nil)
}

// End-to-end smoke test, not an isolated guard: `sender()` can only return a hex whose directory
// entry exists, so this passes however the lookup is guarded.
@Test func pushOutcomeNamesNobodyOutsideTheDirectory() async {
    let me = Identity()
    let out = await handler(identity: me, blocked: [], senders: .empty)
        .outcome(userInfo: userInfo([lxmfPacket(from: Identity(), to: me)]))
    #expect(out.sender == nil)
}

@Test func pushOutcomeSuppressionIsUnchanged() async {
    let me = Identity(), blocked = Identity()
    let out = await handler(identity: me, blocked: [blocked.lxmfDeliveryHash.pushHex],
                            senders: directory([blocked: "B"]))
        .outcome(userInfo: userInfo([lxmfPacket(from: blocked, to: me)]))
    #expect(out.verdict == .suppress)
}

@Test func pushOutcomeKeepsTheSenderPastTheDeadline() async {
    // Same shape as pushVerdictSurvivesASenderThatOutlivesTheDeadline: an 8 s uncancellable
    // sendFrames, a 200 ms deadline.
    let me = Identity(), alice = Identity()
    let out = await slowHandler(identity: me, senders: directory([alice: "Alice"]))
        .outcome(userInfo: userInfo([lxmfPacket(from: alice, to: me)]))
    #expect(out.sender?.entry.name == "Alice")
}
