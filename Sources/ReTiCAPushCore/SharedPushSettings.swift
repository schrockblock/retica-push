import Foundation

/// The last successful registration, so a relaunch can skip an identical POST (spec §1).
public struct RegistrationRecord: Equatable, Sendable, Codable {
    public var tokenHex: String
    public var registeredAt: Date
    public init(tokenHex: String, registeredAt: Date) {
        self.tokenHex = tokenHex
        self.registeredAt = registeredAt
    }
}

/// What the app writes for the service extension to read: where the hub is (so a proof goes to
/// the right socket) and where the identity is (the Keychain location). Stored as one JSON blob
/// in the app-group defaults suite under `SharedPushSettingsStore.key`.
public struct SharedPushSettings: Equatable, Sendable, Codable {
    public var hubHost: String
    public var hubPort: Int
    public var keychainService: String
    public var keychainAccessGroup: String?
    public var lastRegistration: RegistrationRecord?

    public init(hubHost: String = "", hubPort: Int = 0, keychainService: String = "",
                keychainAccessGroup: String? = nil, lastRegistration: RegistrationRecord? = nil) {
        self.hubHost = hubHost
        self.hubPort = hubPort
        self.keychainService = keychainService
        self.keychainAccessGroup = keychainAccessGroup
        self.lastRegistration = lastRegistration
    }
}

public struct SharedPushSettingsStore: Sendable {
    public static let key = "retica.push.settings"

    /// The app-group suite. nil means `UserDefaults.standard` (never what the extension reads).
    public let suiteName: String?

    public init(suiteName: String?) { self.suiteName = suiteName }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    /// Defaults when nothing is stored or the blob does not decode.
    public func load() -> SharedPushSettings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(SharedPushSettings.self, from: data)
        else { return SharedPushSettings() }
        return settings
    }

    public func save(_ settings: SharedPushSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
