import Testing
import Foundation
import ComposableArchitecture
import ReTiCA
@testable import ReTiCAPush

private let token = Data([0x01, 0x02, 0x03, 0x04])
private let hubHex = String(repeating: "ab", count: 16)
private let hub = Data(repeating: 0xAB, count: 16)
private func packet(_ n: UInt8) -> Data { Data([0x00, 0x00, n, n &+ 1, n &+ 2]) }

@Test @MainActor func pushFeatureLifecycleDisableUnregistersAndClears() async throws {
    let platform = PlatformSpy()
    let storage = PushStorage.temporary()
    let record = RegistrationRecord(tokenHex: "01020304", registeredAt: testNow)
    storage.settings.save(SharedPushSettings(lastRegistration: record))
    let store = makePushStore(platform: platform, storage: storage) { state in
        state.$enabled.withLock { $0 = true }
        state.$hubHex.withLock { $0 = hubHex }
        state.deviceToken = token
        state.status = .registered(testNow)
        state.lastRegistration = record
    }
    await store.send(.setEnabled(false)) {
        $0.$enabled.withLock { $0 = false }
        $0.deviceToken = nil
        $0.status = .idle
        $0.lastRegistration = nil
    }
    await store.receive(.delegate(.sendRegistration(hub: hub, path: "/unregister", data: RegistrationWire.unregisterRequest())))
    await store.receive(.unregisterFinished)
    #expect(platform.unregisters.value == 1)
    #expect(storage.settings.load().lastRegistration == nil)
}

@Test @MainActor func pushFeatureLifecycleAppLaunchedEnabledRegistersAndDrains() async {
    let platform = PlatformSpy()
    let store = makePushStore(platform: platform) { state in
        state.$enabled.withLock { $0 = true }
    }
    await store.send(.appLaunched)
    await store.receive(.inboxDrained([]))
    await store.finish()
    #expect(platform.authorizations.value == 1)
    #expect(platform.registers.value == 1)
}

@Test @MainActor func pushFeatureLifecycleAppLaunchedDisabledOnlyDrains() async {
    let platform = PlatformSpy()
    let store = makePushStore(platform: platform)
    await store.send(.appLaunched)
    await store.receive(.inboxDrained([]))
    await store.finish()
    #expect(platform.authorizations.value == 0)
    #expect(platform.registers.value == 0)
}

@Test @MainActor func pushFeatureLifecycleAppLaunchedDeniedShowsGuidance() async {
    // Re-checking permission on every launch must surface a revoked grant, not just rely on the
    // stale `enabled` flag to keep registering a device that can no longer receive anything.
    let platform = PlatformSpy(granted: false)
    let store = makePushStore(platform: platform) { state in
        state.$enabled.withLock { $0 = true }
    }
    await store.send(.appLaunched)
    // The permission check and the inbox drain are two independently concurrent effects from the
    // same `.merge`; their relative arrival order is not guaranteed, so wait for both to finish
    // and fold the received actions into state rather than asserting on a single `.receive`.
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.status == .failed(PushFeature.deniedText))
    #expect(platform.registers.value == 0)
    #expect(store.state.enabled == true)
}

@Test @MainActor func pushFeatureLifecycleHubChangedWhileEnabledRewritesSettings() async {
    let storage = PushStorage.temporary()
    let store = makePushStore(storage: storage) { state in
        state.$enabled.withLock { $0 = true }
    }
    await store.send(.hubChanged(host: "new.example.net", port: 4243)) {
        $0.hubHost = "new.example.net"
        $0.hubPort = 4243
    }
    await store.finish()
    #expect(storage.settings.load().hubHost == "new.example.net")
    #expect(storage.settings.load().hubPort == 4243)
}

@Test @MainActor func pushFeatureLifecycleHubChangedWhileDisabledLeavesSettings() async {
    let storage = PushStorage.temporary()
    let store = makePushStore(storage: storage)
    await store.send(.hubChanged(host: "new.example.net", port: 4243)) {
        $0.hubHost = "new.example.net"
        $0.hubPort = 4243
    }
    await store.finish()
    #expect(storage.settings.load().hubHost == "")
}

@Test @MainActor func pushFeatureLifecycleDrainWithPacketsEmitsInject() async throws {
    let storage = PushStorage.temporary()
    try storage.inbox.append(packet(1))
    try storage.inbox.append(packet(2))
    let store = makePushStore(storage: storage)
    await store.send(.drainInbox)
    await store.receive(.inboxDrained([packet(1), packet(2)]))
    await store.receive(.delegate(.inject(packets: [packet(1), packet(2)])))
    #expect(try storage.inbox.count() == 0)
}

@Test @MainActor func pushFeatureLifecycleDrainEmptyEmitsNothing() async {
    let store = makePushStore()
    store.exhaustivity = .on
    await store.send(.drainInbox)
    await store.receive(.inboxDrained([]))
    await store.finish()
}

@Test @MainActor func pushFeatureLifecycleLateRegistrationAfterDisableIsIgnored() async {
    // The POST was in flight when the user turned push off: its result must not resurrect `.registered`.
    let store = makePushStore()
    store.exhaustivity = .on
    await store.send(.registrationResponse(.success(Data())))
    await store.finish()
    #expect(store.state.status == .idle)
    #expect(store.state.lastRegistration == nil)
}

@Test @MainActor func pushFeatureLifecycleResponseWhileNotRegisteringIsIgnored() async {
    // A stale /unregister answer after a quick re-enable, before the new token arrived.
    let store = makePushStore { state in
        state.$enabled.withLock { $0 = true }
        state.status = .awaitingToken
    }
    store.exhaustivity = .on
    let unregistered = MsgPack.encode(.map([.init("ok", .bool(true))]))
    await store.send(.registrationResponse(.success(unregistered)))
    await store.send(.registrationResponse(.failure(RegistrationFailure("late"))))
    await store.finish()
    #expect(store.state.status == .awaitingToken)
}

@Test @MainActor func pushFeatureLifecyclePermissionAfterDisableIsIgnored() async {
    // A permission answer from a request issued before the user disabled push must not reach
    // past a now-disabled feature and re-arm it.
    let platform = PlatformSpy()
    let store = makePushStore(platform: platform)
    store.exhaustivity = .on
    await store.send(.permissionResolved(granted: true))
    await store.finish()
    #expect(store.state.status == .idle)
    #expect(store.state.deviceToken == nil)
    #expect(platform.registers.value == 0)
}

@Test @MainActor func pushFeatureLifecycleTokenAfterDisableIsIgnored() async {
    // Same for a device token that arrives after disabling: it must not trigger a registration.
    let store = makePushStore()
    store.exhaustivity = .on
    await store.send(.deviceTokenReceived(Data([1, 2, 3, 4])))
    await store.finish()
    #expect(store.state.status == .idle)
    #expect(store.state.deviceToken == nil)
}

@Test @MainActor func pushFeatureLifecycleTokenFailureAfterDisableIsIgnored() async {
    // And a late token-fetch failure must not overwrite `.idle` with a failure message.
    let store = makePushStore()
    store.exhaustivity = .on
    await store.send(.deviceTokenFailed("x"))
    await store.finish()
    #expect(store.state.status == .idle)
    #expect(store.state.deviceToken == nil)
}

@Test @MainActor func pushFeatureLifecycleHubChangeClearsTheRecordWhileEnabled() async {
    let storage = PushStorage.temporary()
    let record = RegistrationRecord(tokenHex: "01020304", registeredAt: testNow)
    storage.settings.save(SharedPushSettings(lastRegistration: record))
    let store = makePushStore(storage: storage) { state in
        state.$enabled.withLock { $0 = true }
        state.lastRegistration = record
    }
    await store.send(.setHubHex(hubHex)) {
        $0.$hubHex.withLock { $0 = hubHex }
        $0.lastRegistration = nil
    }
    await store.finish()
    #expect(storage.settings.load().lastRegistration == nil)
}

@Test @MainActor func pushFeatureLifecycleHubChangeWhileDisabledKeepsTheRecord() async {
    let storage = PushStorage.temporary()
    let record = RegistrationRecord(tokenHex: "01020304", registeredAt: testNow)
    storage.settings.save(SharedPushSettings(lastRegistration: record))
    let store = makePushStore(storage: storage) { state in
        state.lastRegistration = record
    }
    await store.send(.setHubHex(hubHex)) {
        $0.$hubHex.withLock { $0 = hubHex }
    }
    await store.finish()
    #expect(store.state.lastRegistration == record)
    #expect(storage.settings.load().lastRegistration == record)
}
