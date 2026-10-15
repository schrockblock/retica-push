import Testing
import Foundation
import ComposableArchitecture
import ReTiCA
@testable import ReTiCAPushExtension

private func freshDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "ReTiCAPushVerdictTests-\(UUID().uuidString)", directoryHint: .isDirectory)
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

private func userInfo(_ packets: [Data]) -> [AnyHashable: Any] {
    ["aps": ["alert": ["title": "New message"]],
     "rns": ["v": 1, "packets": packets.map { $0.base64EncodedString() }]]
}

private final class SenderSpy: Sendable {
    let calls = LockIsolated<[(host: String, port: Int, frames: [Data])]>([])
    let hang: Duration?
    init(hang: Duration? = nil) { self.hang = hang }
    var send: @Sendable (String, Int, [Data]) async -> Void {
        { host, port, frames in
            self.calls.withValue { $0.append((host, port, frames)) }
            if let hang = self.hang { try? await Task.sleep(for: hang) }
        }
    }
}

private let settings = SharedPushSettings(hubHost: "hub.example.net", hubPort: 4242,
                                          keychainService: "reticulum.identity", keychainAccessGroup: "TEAM.g")

private func handler(inbox: PushInbox = PushInbox(directory: freshDirectory()), identity: Identity?,
                     blocked: Set<String>, sender: SenderSpy = SenderSpy(),
                     deadline: Duration = .seconds(20)) -> PushServiceHandler {
    PushServiceHandler(inbox: inbox, settings: settings, blockedSenders: blocked,
                       loadIdentity: { identity }, sendFrames: sender.send, deadline: deadline)
}

@Test func pushVerdictSuppressesWhenEveryAttributedSenderIsBlocked() async {
    let me = Identity()
    let blocked = Identity()
    let verdict = await handler(identity: me, blocked: [blocked.lxmfDeliveryHash.pushHex])
        .handle(userInfo: userInfo([lxmfPacket(from: blocked, to: me), lxmfPacket(from: blocked, to: me)]))
    #expect(verdict == .suppress)
}

@Test func pushVerdictDeliversWhenOneAttributedSenderIsNotBlocked() async {
    let me = Identity()
    let blocked = Identity()
    let friend = Identity()
    let verdict = await handler(identity: me, blocked: [blocked.lxmfDeliveryHash.pushHex])
        .handle(userInfo: userInfo([lxmfPacket(from: blocked, to: me), lxmfPacket(from: friend, to: me)]))
    #expect(verdict == .deliverOriginal)
}

@Test func pushVerdictDeliversWhenNothingIsAttributable() async {
    let me = Identity()
    let verdict = await handler(identity: me, blocked: [Identity().lxmfDeliveryHash.pushHex])
        .handle(userInfo: userInfo([plainPacket(to: me)]))
    #expect(verdict == .deliverOriginal)
}

@Test func pushVerdictDeliversWhenTheListIsEmpty() async {
    let me = Identity()
    let verdict = await handler(identity: me, blocked: [])
        .handle(userInfo: userInfo([lxmfPacket(from: Identity(), to: me)]))
    #expect(verdict == .deliverOriginal)
}

@Test func pushVerdictDeliversWithoutAnIdentity() async {
    let me = Identity()
    let blocked = Identity()
    let verdict = await handler(identity: nil, blocked: [blocked.lxmfDeliveryHash.pushHex])
        .handle(userInfo: userInfo([lxmfPacket(from: blocked, to: me)]))
    #expect(verdict == .deliverOriginal)
}

@Test func pushVerdictDeliversForAMalformedPayload() async {
    let verdict = await handler(identity: Identity(), blocked: [Identity().lxmfDeliveryHash.pushHex])
        .handle(userInfo: ["aps": ["alert": "x"]])
    #expect(verdict == .deliverOriginal)
}

@Test func pushVerdictDeliversWhenAnUnattributablePacketRidesAlong() async {
    // Spec A6: an unattributable packet may be someone else's, so it vetoes suppression.
    let me = Identity()
    let blocked = Identity()
    let verdict = await handler(identity: me, blocked: [blocked.lxmfDeliveryHash.pushHex])
        .handle(userInfo: userInfo([lxmfPacket(from: blocked, to: me), plainPacket(to: me)]))
    #expect(verdict == .deliverOriginal)
}

@Test func pushVerdictDeliversForALinkRequestBesideABlockedPacket() async throws {
    // A friend's link-based client sends a LINKREQUEST in the same batched push as a blocked
    // sender's packet: the friend's wake banner must show.
    let me = Identity()
    let blocked = Identity()
    let linkRequest = try Packet(packetType: .linkRequest, destinationType: .single,
                                 destinationHash: me.lxmfDeliveryHash, payload: Data(repeating: 7, count: 64)).packed()
    let verdict = await handler(identity: me, blocked: [blocked.lxmfDeliveryHash.pushHex])
        .handle(userInfo: userInfo([lxmfPacket(from: blocked, to: me), linkRequest]))
    #expect(verdict == .deliverOriginal)
}

/// Hangs for `seconds` in a way cancellation cannot interrupt, like an NWConnection callback.
private func uncancellableSender(seconds: Double) -> @Sendable (String, Int, [Data]) async -> Void {
    { _, _, _ in
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
        }
    }
}

@Test func pushVerdictSurvivesASenderThatOutlivesTheDeadline() async {
    // The sender ignores cancellation, like an NWConnection callback: the verdict was parked
    // before that wait, so the deadline path still returns it.
    let me = Identity()
    let blocked = Identity()
    let handler = PushServiceHandler(inbox: PushInbox(directory: freshDirectory()), settings: settings,
                                     blockedSenders: [blocked.lxmfDeliveryHash.pushHex],
                                     loadIdentity: { me }, sendFrames: uncancellableSender(seconds: 8),
                                     deadline: .milliseconds(200))
    let clock = ContinuousClock()
    let start = clock.now
    let verdict = await handler.handle(userInfo: userInfo([lxmfPacket(from: blocked, to: me)]))
    #expect(clock.now - start < .seconds(5))
    #expect(verdict == .suppress)
}

@Test func pushVerdictStillStashesAndProvesABlockedSender() async throws {
    let me = Identity()
    let blocked = Identity()
    let inbox = PushInbox(directory: freshDirectory())
    let sender = SenderSpy()
    let raw = lxmfPacket(from: blocked, to: me)
    let verdict = await handler(inbox: inbox, identity: me, blocked: [blocked.lxmfDeliveryHash.pushHex], sender: sender)
        .handle(userInfo: userInfo([raw]))
    #expect(verdict == .suppress)
    #expect(try inbox.drain() == [raw])
    let call = try #require(sender.calls.value.first)
    #expect(call.frames.count == 1)
}

@Test func pushVerdictCountsAPacketThatCouldNotBeStashed() async {
    // A full disk must not turn a blocked sender's banner back on.
    let me = Identity()
    let blocked = Identity()
    let verdict = await handler(inbox: PushInbox(directory: URL(filePath: "/dev/null/ReTiCAPush-inbox")),
                                identity: me, blocked: [blocked.lxmfDeliveryHash.pushHex])
        .handle(userInfo: userInfo([lxmfPacket(from: blocked, to: me)]))
    #expect(verdict == .suppress)
}

@Test func pushVerdictMatchesUpperCaseHexInTheList() async {
    let me = Identity()
    let blocked = Identity()
    let verdict = await handler(identity: me, blocked: [blocked.lxmfDeliveryHash.pushHex.uppercased()])
        .handle(userInfo: userInfo([lxmfPacket(from: blocked, to: me)]))
    #expect(verdict == .suppress)
}
