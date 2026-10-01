import Testing
import Foundation
import ComposableArchitecture
import ReTiCA
@testable import ReTiCAPush

private let token = Data([0x01, 0x02, 0x03, 0x04])
private let hours: TimeInterval = 60 * 60

@Test @MainActor func pushFeatureTokenRegistersAndRecordsOnSuccess() async throws {
    let me = Identity()
    let registration = RegistrationSpy()
    let storage = PushStorage.temporary()
    let store = makePushStore(identity: me, registration: registration, storage: storage) { state in
        state.$enabled.withLock { $0 = true }
        state.$registrationURL.withLock { $0 = "https://hub.example.net/push" }
        state.status = .awaitingToken
    }
    await store.send(.deviceTokenReceived(token)) {
        $0.deviceToken = token
        $0.status = .registering
    }
    await store.receive(.registrationFinished(.success(testNow))) {
        $0.status = .registered(testNow)
        $0.lastRegistration = RegistrationRecord(tokenHex: "01020304", registeredAt: testNow)
    }
    let (sent, url) = try #require(registration.registered.value.first)
    #expect(url.absoluteString == "https://hub.example.net/push")
    #expect(sent.domain == .register)
    #expect(sent.verify())
    #expect(sent.registration.publicKey == me.publicKey)
    #expect(sent.registration.pushToken == token)
    #expect(sent.registration.bundleID == "co.example.app")
    #expect(sent.registration.environment == .sandbox)
    #expect(sent.registration.issuedAt == 1_700_000_000)
    #expect(storage.settings.load().lastRegistration == RegistrationRecord(tokenHex: "01020304", registeredAt: testNow))
}

@Test @MainActor func pushFeatureTokenSkipsWhenSameTokenRegisteredWithin24h() async {
    let registration = RegistrationSpy()
    let earlier = testNow.addingTimeInterval(-1 * hours)
    let store = makePushStore(registration: registration) { state in
        state.$enabled.withLock { $0 = true }
        state.$registrationURL.withLock { $0 = "https://hub.example.net/push" }
        state.lastRegistration = RegistrationRecord(tokenHex: "01020304", registeredAt: earlier)
    }
    await store.send(.deviceTokenReceived(token)) {
        $0.deviceToken = token
        $0.status = .registered(earlier)
    }
    await store.finish()
    #expect(registration.registered.value.isEmpty)
}

@Test @MainActor func pushFeatureTokenReregistersAfter24h() async {
    let registration = RegistrationSpy()
    let store = makePushStore(registration: registration) { state in
        state.$enabled.withLock { $0 = true }
        state.$registrationURL.withLock { $0 = "https://hub.example.net/push" }
        state.lastRegistration = RegistrationRecord(tokenHex: "01020304", registeredAt: testNow.addingTimeInterval(-25 * hours))
    }
    await store.send(.deviceTokenReceived(token)) {
        $0.deviceToken = token
        $0.status = .registering
    }
    await store.receive(.registrationFinished(.success(testNow)))
    #expect(registration.registered.value.count == 1)
}

@Test @MainActor func pushFeatureTokenReregistersWhenTokenChanges() async {
    let registration = RegistrationSpy()
    let store = makePushStore(registration: registration) { state in
        state.$enabled.withLock { $0 = true }
        state.$registrationURL.withLock { $0 = "https://hub.example.net/push" }
        state.lastRegistration = RegistrationRecord(tokenHex: "ffffffff", registeredAt: testNow.addingTimeInterval(-1 * hours))
    }
    await store.send(.deviceTokenReceived(token)) {
        $0.deviceToken = token
        $0.status = .registering
    }
    await store.receive(.registrationFinished(.success(testNow)))
    #expect(registration.registered.value.count == 1)
}

@Test @MainActor func pushFeatureTokenRegistrationFailureKeepsOldRecord() async {
    let registration = RegistrationSpy(failure: .server(status: 401, body: "nope"))
    let old = RegistrationRecord(tokenHex: "ffffffff", registeredAt: testNow.addingTimeInterval(-1 * hours))
    let store = makePushStore(registration: registration) { state in
        state.$enabled.withLock { $0 = true }
        state.$registrationURL.withLock { $0 = "https://hub.example.net/push" }
        state.lastRegistration = old
    }
    await store.send(.deviceTokenReceived(token)) {
        $0.deviceToken = token
        $0.status = .registering
    }
    await store.receive(.registrationFinished(.failure(RegistrationFailure("Server returned 401: nope")))) {
        $0.status = .failed("Server returned 401: nope")
    }
    #expect(store.state.lastRegistration == old)
}

@Test @MainActor func pushFeatureTokenInvalidURLFailsWithoutPosting() async {
    let registration = RegistrationSpy()
    let store = makePushStore(registration: registration) { state in
        state.$enabled.withLock { $0 = true }
        state.$registrationURL.withLock { $0 = "ftp://hub.example.net/push" }
    }
    await store.send(.deviceTokenReceived(token)) {
        $0.deviceToken = token
        $0.status = .failed("Invalid registration URL")
    }
    await store.finish()
    #expect(registration.registered.value.isEmpty)
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
