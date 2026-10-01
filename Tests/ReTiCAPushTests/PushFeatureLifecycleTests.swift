import Testing
import Foundation
import ComposableArchitecture
import ReTiCA
@testable import ReTiCAPush

private let token = Data([0x01, 0x02, 0x03, 0x04])
private func packet(_ n: UInt8) -> Data { Data([0x00, 0x00, n, n &+ 1, n &+ 2]) }

@Test @MainActor func pushFeatureLifecycleDisableUnregistersAndClears() async throws {
    let platform = PlatformSpy()
    let registration = RegistrationSpy()
    let storage = PushStorage.temporary()
    let record = RegistrationRecord(tokenHex: "01020304", registeredAt: testNow)
    storage.settings.save(SharedPushSettings(lastRegistration: record))
    let store = makePushStore(platform: platform, registration: registration, storage: storage) { state in
        state.$enabled.withLock { $0 = true }
        state.$registrationURL.withLock { $0 = "https://hub.example.net/push" }
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
    await store.receive(.unregisterFinished)
    #expect(platform.unregisters.value == 1)
    let (sent, _) = try #require(registration.unregistered.value.first)
    #expect(sent.domain == .unregister)
    #expect(sent.verify())
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
    #expect(platform.registers.value == 1)
}

@Test @MainActor func pushFeatureLifecycleAppLaunchedDisabledOnlyDrains() async {
    let platform = PlatformSpy()
    let store = makePushStore(platform: platform)
    await store.send(.appLaunched)
    await store.receive(.inboxDrained([]))
    await store.finish()
    #expect(platform.registers.value == 0)
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
    await store.send(.registrationFinished(.success(testNow)))
    await store.finish()
    #expect(store.state.status == .idle)
    #expect(store.state.lastRegistration == nil)
}
