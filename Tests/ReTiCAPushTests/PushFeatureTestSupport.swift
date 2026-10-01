import Foundation
import ComposableArchitecture
import ReTiCA
@testable import ReTiCAPush

let testNow = Date(timeIntervalSince1970: 1_700_000_000)

/// Counts calls to the three platform verbs and answers permission with `granted`.
final class PlatformSpy: Sendable {
    let authorizations = LockIsolated(0)
    let registers = LockIsolated(0)
    let unregisters = LockIsolated(0)
    let granted: Bool

    init(granted: Bool = true) { self.granted = granted }

    var platform: PushPlatform {
        PushPlatform(
            requestAuthorization: { self.authorizations.withValue { $0 += 1 }; return self.granted },
            registerForRemoteNotifications: { self.registers.withValue { $0 += 1 } },
            unregisterForRemoteNotifications: { self.unregisters.withValue { $0 += 1 } })
    }
}

/// Records every registration call and answers with `result` (nil = success).
final class RegistrationSpy: Sendable {
    let registered = LockIsolated<[(SignedRegistration, URL)]>([])
    let unregistered = LockIsolated<[(SignedRegistration, URL)]>([])
    let failure: RegistrationClient.Failure?

    init(failure: RegistrationClient.Failure? = nil) { self.failure = failure }

    var client: RegistrationClient {
        RegistrationClient(
            register: { signed, url in
                self.registered.withValue { $0.append((signed, url)) }
                if let failure = self.failure { throw failure }
            },
            unregister: { signed, url in
                self.unregistered.withValue { $0.append((signed, url)) }
            })
    }
}

@MainActor
func makePushStore(identity: Identity = Identity(),
                   platform: PlatformSpy = PlatformSpy(),
                   registration: RegistrationSpy = RegistrationSpy(),
                   storage: PushStorage = .temporary(),
                   configure: ((inout PushFeature.State) -> Void)? = nil) -> TestStoreOf<PushFeature> {
    var initial = PushFeature.State(identity: identity, bundleID: "co.example.app", environment: .sandbox,
                                    storage: storage, keychainService: "reticulum.identity",
                                    keychainAccessGroup: "TEAM.co.example.identity")
    configure?(&initial)
    let store = TestStore(initialState: initial) {
        PushFeature()
    } withDependencies: {
        $0.pushPlatform = platform.platform
        $0.registrationClient = registration.client
        $0.date = .constant(testNow)
        // Isolate `@Shared(.appStorage(...))` per test: without a fresh suite, `enabled` and
        // `registrationURL` would persist across tests through the real `UserDefaults.standard`.
        $0.defaultAppStorage = UserDefaults(suiteName: "ReTiCAPushTests.\(UUID().uuidString)")!
    }
    store.exhaustivity = .off
    return store
}
