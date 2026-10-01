import Testing
import Foundation
import ComposableArchitecture
import ReTiCA
@testable import ReTiCAPush

@Test @MainActor func pushFeatureEnableRequestsPermissionAndRegistersWhenGranted() async {
    let platform = PlatformSpy(granted: true)
    let store = makePushStore(platform: platform)
    await store.send(.setEnabled(true)) {
        $0.$enabled.withLock { $0 = true }
        $0.status = .awaitingPermission
    }
    await store.receive(.permissionResolved(granted: true)) { $0.status = .awaitingToken }
    await store.finish()
    #expect(platform.authorizations.value == 1)
    #expect(platform.registers.value == 1)
}

@Test @MainActor func pushFeatureEnableDeniedKeepsTheToggleOnWithAFailure() async {
    let platform = PlatformSpy(granted: false)
    let store = makePushStore(platform: platform)
    await store.send(.setEnabled(true)) {
        $0.$enabled.withLock { $0 = true }
        $0.status = .awaitingPermission
    }
    await store.receive(.permissionResolved(granted: false)) {
        $0.status = .failed("Notifications are off for ReTiCaMsgr in Settings")
    }
    await store.finish()
    #expect(store.state.enabled == true)
    #expect(platform.registers.value == 0)
}

@Test @MainActor func pushFeatureEnableWritesHubAndKeychainToSharedSettings() async {
    let storage = PushStorage.temporary()
    let store = makePushStore(storage: storage) { state in
        state.hubHost = "hub.example.net"
        state.hubPort = 4242
    }
    await store.send(.setEnabled(true))
    await store.skipReceivedActions(strict: false)
    let saved = storage.settings.load()
    #expect(saved.hubHost == "hub.example.net")
    #expect(saved.hubPort == 4242)
    #expect(saved.keychainService == "reticulum.identity")
    #expect(saved.keychainAccessGroup == "TEAM.co.example.identity")
}

@Test @MainActor func pushFeatureEnableIsIdempotent() async {
    let platform = PlatformSpy(granted: true)
    let store = makePushStore(platform: platform) { state in
        state.$enabled.withLock { $0 = true }
        state.status = .awaitingToken
    }
    await store.send(.setEnabled(true))
    await store.finish()
    #expect(platform.authorizations.value == 0)
    #expect(store.state.status == .awaitingToken)
}

@Test func pushFeatureEnableStatusTextDescribesEachCase() {
    typealias Status = PushFeature.State.Status
    #expect(Status.idle.displayText == "Off")
    #expect(Status.awaitingPermission.displayText == "Waiting for permission…")
    #expect(Status.awaitingToken.displayText == "Waiting for a device token…")
    #expect(Status.registering.displayText == "Registering…")
    #expect(Status.registered(testNow).displayText.hasPrefix("Registered "))
    #expect(Status.failed("boom").displayText == "boom")
}
