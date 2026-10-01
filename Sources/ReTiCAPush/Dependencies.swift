import Foundation
import ComposableArchitecture
import ReTiCAPushCore

/// The three UIKit calls `PushFeature` needs. The host app supplies the real one through
/// `withDependencies` when it builds its store (`UNUserNotificationCenter.requestAuthorization`,
/// `UIApplication.registerForRemoteNotifications`, `unregisterForRemoteNotifications`). The
/// `liveValue` here is a no-op placeholder: without the app's override, enabling push silently
/// waits for a token that never comes.
public struct PushPlatform: Sendable {
    public var requestAuthorization: @Sendable () async -> Bool
    public var registerForRemoteNotifications: @Sendable () async -> Void
    public var unregisterForRemoteNotifications: @Sendable () async -> Void

    public init(requestAuthorization: @escaping @Sendable () async -> Bool,
                registerForRemoteNotifications: @escaping @Sendable () async -> Void,
                unregisterForRemoteNotifications: @escaping @Sendable () async -> Void) {
        self.requestAuthorization = requestAuthorization
        self.registerForRemoteNotifications = registerForRemoteNotifications
        self.unregisterForRemoteNotifications = unregisterForRemoteNotifications
    }

    public static let noop = PushPlatform(requestAuthorization: { false },
                                          registerForRemoteNotifications: {},
                                          unregisterForRemoteNotifications: {})
}

extension PushPlatform: DependencyKey {
    public static let liveValue = PushPlatform.noop
    public static let testValue = PushPlatform(
        requestAuthorization: unimplemented("PushPlatform.requestAuthorization", placeholder: false),
        registerForRemoteNotifications: unimplemented("PushPlatform.registerForRemoteNotifications"),
        unregisterForRemoteNotifications: unimplemented("PushPlatform.unregisterForRemoteNotifications"))
}

extension RegistrationClient: DependencyKey {
    public static var liveValue: RegistrationClient { .live() }
    public static let testValue = RegistrationClient(
        register: unimplemented("RegistrationClient.register"),
        unregister: unimplemented("RegistrationClient.unregister"))
}

public extension DependencyValues {
    var pushPlatform: PushPlatform {
        get { self[PushPlatform.self] }
        set { self[PushPlatform.self] = newValue }
    }

    var registrationClient: RegistrationClient {
        get { self[RegistrationClient.self] }
        set { self[RegistrationClient.self] = newValue }
    }
}
