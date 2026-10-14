import Foundation
import ComposableArchitecture
import ReTiCA
import Testing
@testable import ReTiCAPush
@testable import ReTiCAPushCore

private let hubHex = "ef92bcaeb90947a9fc2228affabdce13"
private let dest = Data(repeating: 0x42, count: 16)
private let token = Data(repeating: 0x01, count: 32)

@MainActor
private func registeredNbhdStore() async -> TestStoreOf<PushFeature> {
    let store = makeNbhdPushStore(destinationHash: dest)
    await store.send(.setHubHex(hubHex))
    await store.send(.setEnabled(true))
    await store.receive(\.permissionResolved)
    await store.send(.deviceTokenReceived(token))
    let expected = RegistrationWire.registerRequest(token: token, environment: .sandbox,
                                                    bundleID: "co.example.nbhd", aspects: ["nbhd", "sync"])
    // `Action` is Equatable, so the emitted delegate is matched by value: hub, path AND body.
    await store.receive(.delegate(.sendRegistration(hub: Data(pushHex: hubHex)!, path: RegistrationWire.registerPath,
                                                    data: expected)))
    let ok = MsgPack.encode(.map([.init("ok", .bool(true)), .init("destination_hash", .bin(dest)),
                                  .init("expires_at", .uint(1))]))
    await store.send(.registrationResponse(.success(ok))) {
        $0.status = .registered(testNow)
    }
    return store
}

@MainActor @Suite struct PushFeatureAspectsTests {
    @Test func registrationCarriesAspectsAndAcceptsThatDestination() async {
        _ = await registeredNbhdStore()
    }

    @Test func wrongDestinationIsRefused() async {
        let store = makeNbhdPushStore(destinationHash: dest)
        await store.send(.setHubHex(hubHex))
        await store.send(.setEnabled(true))
        await store.receive(\.permissionResolved)
        await store.send(.deviceTokenReceived(token))
        let other = MsgPack.encode(.map([.init("ok", .bool(true)), .init("destination_hash", .bin(Data(repeating: 9, count: 16))),
                                         .init("expires_at", .uint(1))]))
        await store.send(.registrationResponse(.success(other))) {
            $0.status = .failed(PushFeature.wrongDestinationText)
        }
    }

    @Test func disablingUnregistersWithAspects() async {
        let store = await registeredNbhdStore()
        await store.send(.setEnabled(false))
        await store.receive(.delegate(.sendRegistration(hub: Data(pushHex: hubHex)!, path: RegistrationWire.unregisterPath,
                                                        data: RegistrationWire.unregisterRequest(aspects: ["nbhd", "sync"]))))
    }

    @Test func deniedTextNamesTheApp() {
        let state = PushFeature.State(destinationHash: Data(count: 16), aspects: ["nbhd", "sync"], appName: "Nbhd",
                                      bundleID: "b", environment: .sandbox, storage: .temporary(),
                                      keychainService: "s", keychainAccessGroup: nil)
        #expect(state.deniedText == "Notifications are off for Nbhd in Settings")
    }

    @Test func permissionDeniedShowsTheAppsText() async {
        let store = makeNbhdPushStore(destinationHash: dest, platform: PlatformSpy(granted: false))
        await store.send(.setHubHex(hubHex))
        await store.send(.setEnabled(true))
        await store.receive(\.permissionResolved) {
            $0.status = .failed("Notifications are off for Nbhd in Settings")
        }
    }

    @Test func sameHubHexIsANoOpWhileRegistered() async {
        let store = await registeredNbhdStore()
        store.exhaustivity = .on
        // The unguarded reducer would clear lastRegistration and flip status to "hub changed".
        await store.send(.setHubHex(hubHex))
        await store.send(.setHubHex("  \(hubHex)\n"))
    }

    @Test func legacyInitRegistersLxmfDelivery() {
        let identity = Identity()
        let state = PushFeature.State(identity: identity, bundleID: "b", environment: .sandbox, storage: .temporary(),
                                      keychainService: "s", keychainAccessGroup: nil)
        #expect(state.destinationHash == identity.lxmfDeliveryHash)
        #expect(state.destinationHash.count == 16)
        #expect(state.aspects == nil)
        #expect(state.appName == "ReTiCaMsgr")
        #expect(state.deniedText == "Notifications are off for ReTiCaMsgr in Settings")
    }
}
