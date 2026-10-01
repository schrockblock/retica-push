import Testing
import Foundation
import Security
import ComposableArchitecture
import ReTiCA
import ReTiCAKeychain
@testable import ReTiCAPushExtension

private func freshDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "ReTiCAPushExtTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private func dataPacket(to me: Identity) -> Data {
    let dest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                           aspects: LXMessage.deliveryAspects, identity: me)!
    return try! Packet.data(to: dest, plaintext: Data("hi".utf8)).packed()
}

private func userInfo(_ packets: [Data]) -> [AnyHashable: Any] {
    ["aps": ["alert": ["title": "New message"]],
     "rns": ["v": 1, "packets": packets.map { $0.base64EncodedString() }]]
}

/// Records what was sent and optionally hangs.
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

private func handler(inbox: PushInbox, identity: Identity?, sender: SenderSpy,
                     deadline: Duration = .seconds(20)) -> PushServiceHandler {
    PushServiceHandler(inbox: inbox, settings: settings, loadIdentity: { identity },
                       sendFrames: sender.send, deadline: deadline)
}

@Test func pushServiceHandlerStashesAndProvesADataPacket() async throws {
    let me = Identity()
    let inbox = PushInbox(directory: freshDirectory())
    let sender = SenderSpy()
    let raw = dataPacket(to: me)
    await handler(inbox: inbox, identity: me, sender: sender).handle(userInfo: userInfo([raw]))
    #expect(try inbox.drain() == [raw])
    let call = try #require(sender.calls.value.first)
    #expect(call.frames.count == 1)
    var deframer = HDLCDeframer()
    let frame = try #require(deframer.ingest(call.frames[0]).first)
    let proof = try #require(Packet(raw: frame))
    #expect(proof.packetType == .proof)
    #expect(me.validate(signature: proof.payload, message: Packet(raw: raw)!.packetHash))
}

@Test func pushServiceHandlerUsesTheConfiguredHub() async throws {
    let me = Identity()
    let sender = SenderSpy()
    await handler(inbox: PushInbox(directory: freshDirectory()), identity: me, sender: sender)
        .handle(userInfo: userInfo([dataPacket(to: me)]))
    let call = try #require(sender.calls.value.first)
    #expect(call.host == "hub.example.net")
    #expect(call.port == 4242)
}

@Test func pushServiceHandlerStashesButDoesNotProveForeignOrFlaggedPackets() async throws {
    let me = Identity()
    let inbox = PushInbox(directory: freshDirectory())
    let sender = SenderSpy()
    let foreign = dataPacket(to: Identity())
    let announce = try Packet(packetType: .announce, destinationType: .single,
                              destinationHash: me.lxmfDeliveryHash, payload: Data(repeating: 1, count: 40)).packed()
    var flagged = dataPacket(to: me)
    flagged[0] |= 0x80
    await handler(inbox: inbox, identity: me, sender: sender).handle(userInfo: userInfo([foreign, announce, flagged]))
    #expect(try inbox.count() == 3)
    #expect(sender.calls.value.isEmpty)
}

@Test func pushServiceHandlerWithoutIdentityStashesOnly() async throws {
    let me = Identity()
    let inbox = PushInbox(directory: freshDirectory())
    let sender = SenderSpy()
    await handler(inbox: inbox, identity: nil, sender: sender).handle(userInfo: userInfo([dataPacket(to: me)]))
    #expect(try inbox.count() == 1)
    #expect(sender.calls.value.isEmpty)
}

@Test func pushServiceHandlerMalformedPayloadDoesNothing() async throws {
    let inbox = PushInbox(directory: freshDirectory())
    let sender = SenderSpy()
    await handler(inbox: inbox, identity: Identity(), sender: sender).handle(userInfo: ["aps": ["alert": "x"]])
    #expect(try inbox.count() == 0)
    #expect(sender.calls.value.isEmpty)
}

@Test func pushServiceHandlerReturnsWhenTheSenderHangs() async {
    let me = Identity()
    let sender = SenderSpy(hang: .seconds(10))
    let clock = ContinuousClock()
    let start = clock.now
    await handler(inbox: PushInbox(directory: freshDirectory()), identity: me, sender: sender, deadline: .milliseconds(200))
        .handle(userInfo: userInfo([dataPacket(to: me)]))
    #expect(clock.now - start < .seconds(2))
}

@Test func pushServiceHandlerKeychainLoaderReturnsTheStoredIdentity() {
    let me = Identity()
    let location = IdentityKeychain.Location(service: "reticulum.identity", accessGroup: "TEAM.g")
    let keychain = InMemoryKeychain([location: me.privateKey!])
    let load = KeychainIdentityLoader.loader(service: "reticulum.identity", accessGroup: "TEAM.g", ops: keychain.ops)
    #expect(load() == me)
}

@Test func pushServiceHandlerKeychainLoaderLockedReturnsNil() {
    let location = IdentityKeychain.Location(service: "reticulum.identity", accessGroup: "TEAM.g")
    let keychain = InMemoryKeychain([location: Identity().privateKey!])
    keychain.failRead(at: location, status: errSecInteractionNotAllowed)
    let load = KeychainIdentityLoader.loader(service: "reticulum.identity", accessGroup: "TEAM.g", ops: keychain.ops)
    #expect(load() == nil)
}
