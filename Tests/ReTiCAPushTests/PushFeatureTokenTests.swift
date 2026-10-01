import Testing
import Foundation
import ComposableArchitecture
import ReTiCA
@testable import ReTiCAPush

private let token = Data([0x01, 0x02, 0x03, 0x04])
private let hours: TimeInterval = 60 * 60
private let hubHex = String(repeating: "ab", count: 16)
private let hub = Data(repeating: 0xAB, count: 16)

private func registered(_ hash: Data) -> Data {
    MsgPack.encode(.map([.init("ok", .bool(true)), .init("destination_hash", .bin(hash)), .init("expires_at", .uint(1_702_592_000))]))
}

@Test @MainActor func pushFeatureTokenRegistersThroughTheHubLink() async throws {
    let me = Identity()
    let storage = PushStorage.temporary()
    let store = makePushStore(identity: me, storage: storage) { state in
        state.$enabled.withLock { $0 = true }
        state.$hubHex.withLock { $0 = hubHex }
        state.status = .awaitingToken
    }
    await store.send(.deviceTokenReceived(token)) {
        $0.deviceToken = token
        $0.status = .registering
    }
    let expectedRequest = RegistrationWire.registerRequest(token: token, environment: .sandbox, bundleID: "co.example.app")
    await store.receive(.delegate(.sendRegistration(hub: hub, path: "/register", data: expectedRequest)))
    await store.send(.registrationResponse(.success(registered(me.lxmfDeliveryHash)))) {
        $0.status = .registered(testNow)
        $0.lastRegistration = RegistrationRecord(tokenHex: "01020304", registeredAt: testNow)
    }
    await store.finish()
    #expect(storage.settings.load().lastRegistration == RegistrationRecord(tokenHex: "01020304", registeredAt: testNow))
}

@Test @MainActor func pushFeatureTokenSkipsWhenSameTokenRegisteredWithin24h() async {
    let earlier = testNow.addingTimeInterval(-1 * hours)
    let store = makePushStore { state in
        state.$enabled.withLock { $0 = true }
        state.$hubHex.withLock { $0 = hubHex }
        state.lastRegistration = RegistrationRecord(tokenHex: "01020304", registeredAt: earlier)
    }
    store.exhaustivity = .on
    await store.send(.deviceTokenReceived(token)) {
        $0.deviceToken = token
        $0.status = .registered(earlier)
    }
    await store.finish()
}

@Test @MainActor func pushFeatureTokenReregistersAfter24h() async {
    let store = makePushStore { state in
        state.$enabled.withLock { $0 = true }
        state.$hubHex.withLock { $0 = hubHex }
        state.lastRegistration = RegistrationRecord(tokenHex: "01020304", registeredAt: testNow.addingTimeInterval(-25 * hours))
    }
    await store.send(.deviceTokenReceived(token)) {
        $0.deviceToken = token
        $0.status = .registering
    }
    await store.receive { if case .delegate(.sendRegistration(hub: hub, path: "/register", _)) = $0 { return true }; return false }
}

@Test @MainActor func pushFeatureTokenReregistersWhenTokenChanges() async {
    let store = makePushStore { state in
        state.$enabled.withLock { $0 = true }
        state.$hubHex.withLock { $0 = hubHex }
        state.lastRegistration = RegistrationRecord(tokenHex: "ffffffff", registeredAt: testNow.addingTimeInterval(-1 * hours))
    }
    await store.send(.deviceTokenReceived(token)) {
        $0.deviceToken = token
        $0.status = .registering
    }
    await store.receive { if case .delegate(.sendRegistration) = $0 { return true }; return false }
}

@Test @MainActor func pushFeatureTokenRefusalKeepsOldRecord() async {
    let old = RegistrationRecord(tokenHex: "ffffffff", registeredAt: testNow.addingTimeInterval(-1 * hours))
    let store = makePushStore { state in
        state.$enabled.withLock { $0 = true }
        state.$hubHex.withLock { $0 = hubHex }
        state.deviceToken = token
        state.status = .registering
        state.lastRegistration = old
    }
    let refusal = MsgPack.encode(.map([.init("ok", .bool(false)), .init("error", .string("rate_limited"))]))
    await store.send(.registrationResponse(.success(refusal))) {
        $0.status = .failed("Hub refused: rate_limited")
    }
    #expect(store.state.lastRegistration == old)
}

@Test @MainActor func pushFeatureTokenInvalidHubFailsWithoutRegistering() async {
    let store = makePushStore { state in
        state.$enabled.withLock { $0 = true }
        state.$hubHex.withLock { $0 = "zz" }
    }
    store.exhaustivity = .on
    await store.send(.deviceTokenReceived(token)) {
        $0.deviceToken = token
        $0.status = .failed("Invalid push hub address")
    }
    await store.finish()
}

@Test @MainActor func pushFeatureTokenFailureSurfacesTheSystemReason() async {
    let store = makePushStore { state in
        state.$enabled.withLock { $0 = true }
        state.status = .awaitingToken
    }
    await store.send(.deviceTokenFailed("no valid aps-environment entitlement")) {
        $0.status = .failed("no valid aps-environment entitlement")
    }
}

@Test @MainActor func pushFeatureTokenWrongDestinationIsRejected() async {
    let store = makePushStore { state in
        state.$enabled.withLock { $0 = true }
        state.deviceToken = token
        state.status = .registering
    }
    await store.send(.registrationResponse(.success(registered(Data(repeating: 0x11, count: 16))))) {
        $0.status = .failed("Hub registered the wrong destination")
    }
    #expect(store.state.lastRegistration == nil)
}

@Test @MainActor func pushFeatureTokenTransportFailureSurfaces() async {
    let store = makePushStore { state in
        state.$enabled.withLock { $0 = true }
        state.deviceToken = token
        state.status = .registering
    }
    await store.send(.registrationResponse(.failure(RegistrationFailure("Push hub unreachable")))) {
        $0.status = .failed("Push hub unreachable")
    }
}
