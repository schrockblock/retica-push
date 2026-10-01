import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCAPushCore

/// Why a registration POST failed, as shown in Settings.
public struct RegistrationFailure: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// Opt-in push wake-ups (spec §1). Owns the toggle, the APNs token and the registration
/// lifecycle, and drains the shared inbox into `delegate(.inject)` for the host app to feed its
/// transport. Never touches ReTiCA's node.
@Reducer
public struct PushFeature {
    public static let deniedText = "Notifications are off for ReTiCaMsgr in Settings"
    public static let invalidURLText = "Invalid registration URL"
    /// A POST is skipped when the same token was registered more recently than this.
    public static let reregistrationInterval: TimeInterval = 24 * 60 * 60

    @ObservableState
    public struct State: Equatable {
        public enum Status: Equatable, Sendable {
            case idle
            case awaitingPermission
            case awaitingToken
            case registering
            case registered(Date)
            case failed(String)

            public var displayText: String {
                switch self {
                case .idle: "Off"
                case .awaitingPermission: "Waiting for permission…"
                case .awaitingToken: "Waiting for a device token…"
                case .registering: "Registering…"
                case let .registered(date): "Registered " + date.formatted(.relative(presentation: .named))
                case let .failed(reason): reason
                }
            }
        }

        public var identity: Identity
        public var bundleID: String
        public var environment: PushRegistration.Environment
        public var storage: PushStorage
        public var keychainService: String
        public var keychainAccessGroup: String?

        @Shared(.appStorage("pushEnabled")) public var enabled: Bool = false
        @Shared(.appStorage("pushRegistrationURL")) public var registrationURL: String = ""

        /// Mirrored from the host app's hub settings by `hubChanged`.
        public var hubHost: String = ""
        public var hubPort: Int = 0
        public var deviceToken: Data? = nil
        public var status: Status = .idle
        public var lastRegistration: RegistrationRecord? = nil

        public init(identity: Identity, bundleID: String, environment: PushRegistration.Environment,
                    storage: PushStorage, keychainService: String, keychainAccessGroup: String?) {
            self.identity = identity
            self.bundleID = bundleID
            self.environment = environment
            self.storage = storage
            self.keychainService = keychainService
            self.keychainAccessGroup = keychainAccessGroup
            self.lastRegistration = storage.settings.load().lastRegistration
        }

        /// What the extension reads. Built from state so every writer agrees.
        var sharedSettings: SharedPushSettings {
            SharedPushSettings(hubHost: hubHost, hubPort: hubPort, keychainService: keychainService,
                               keychainAccessGroup: keychainAccessGroup, lastRegistration: lastRegistration)
        }
    }

    public enum Action: Equatable, BindableAction {
        case setEnabled(Bool)
        case hubChanged(host: String, port: Int)
        case appLaunched
        case permissionResolved(granted: Bool)
        case deviceTokenReceived(Data)
        case deviceTokenFailed(String)
        case registrationFinished(Result<Date, RegistrationFailure>)
        case unregisterFinished
        case drainInbox
        case inboxDrained([Data])
        case delegate(Delegate)
        case binding(BindingAction<State>)

        @CasePathable
        public enum Delegate: Equatable {
            case inject(packets: [Data])
        }
    }

    @Dependency(\.pushPlatform) var platform
    @Dependency(\.registrationClient) var registrationClient
    @Dependency(\.date) var date

    public init() {}

    /// http(s) only. `URL(string:)` accepts far more than that.
    static func registrationURL(from string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host() != nil
        else { return nil }
        return url
    }

    static func failure(for error: Error) -> RegistrationFailure {
        switch error {
        case let RegistrationClient.Failure.server(status, body):
            RegistrationFailure("Server returned \(status): \(body)")
        case let RegistrationClient.Failure.transport(message):
            RegistrationFailure(message)
        default:
            RegistrationFailure(error.localizedDescription)
        }
    }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .setEnabled(true):
                // Idempotent: a second tap while already on must not re-prompt.
                guard !state.enabled else { return .none }
                state.$enabled.withLock { $0 = true }
                state.status = .awaitingPermission
                let settings = state.sharedSettings
                let store = state.storage.settings
                return .run { [platform] send in
                    store.save(settings)
                    let granted = await platform.requestAuthorization()
                    await send(.permissionResolved(granted: granted))
                }

            case .permissionResolved(granted: false):
                guard state.enabled else { return .none }
                state.status = .failed(Self.deniedText)
                return .none

            case .permissionResolved(granted: true):
                guard state.enabled else { return .none }
                state.status = .awaitingToken
                return .run { [platform] _ in await platform.registerForRemoteNotifications() }

            case let .deviceTokenReceived(token):
                guard state.enabled else { return .none }
                state.deviceToken = token
                let tokenHex = token.pushHex
                if let record = state.lastRegistration,
                   record.tokenHex == tokenHex,
                   date.now.timeIntervalSince(record.registeredAt) < Self.reregistrationInterval {
                    state.status = .registered(record.registeredAt)
                    return .none
                }
                guard let url = Self.registrationURL(from: state.registrationURL) else {
                    state.status = .failed(Self.invalidURLText)
                    return .none
                }
                state.status = .registering
                let registration = PushRegistration(
                    publicKey: state.identity.publicKey, pushToken: token, environment: state.environment,
                    bundleID: state.bundleID, issuedAt: UInt64(max(0, date.now.timeIntervalSince1970)))
                guard let signed = registration.signed(with: state.identity, domain: .register) else {
                    state.status = .failed("Could not sign the registration")
                    return .none
                }
                return .run { [registrationClient, date] send in
                    do {
                        try await registrationClient.register(signed, url)
                        await send(.registrationFinished(.success(date.now)))
                    } catch {
                        await send(.registrationFinished(.failure(Self.failure(for: error))))
                    }
                }

            case let .deviceTokenFailed(reason):
                guard state.enabled else { return .none }
                state.status = .failed(reason)
                return .none

            case let .registrationFinished(.success(at)):
                guard state.enabled else { return .none }
                state.status = .registered(at)
                if let token = state.deviceToken {
                    state.lastRegistration = RegistrationRecord(tokenHex: token.pushHex, registeredAt: at)
                }
                let settings = state.sharedSettings
                let store = state.storage.settings
                return .run { _ in store.save(settings) }

            case let .registrationFinished(.failure(failure)):
                guard state.enabled else { return .none }
                state.status = .failed(failure.message)
                return .none

            case .setEnabled(false):
                // Sign the DELETE over the token we are giving up, before clearing it.
                let tokenForUnregister = state.deviceToken ?? Data()
                state.$enabled.withLock { $0 = false }
                state.deviceToken = nil
                state.status = .idle
                state.lastRegistration = nil
                let settings = state.sharedSettings
                let store = state.storage.settings
                let url = Self.registrationURL(from: state.registrationURL)
                let registration = PushRegistration(
                    publicKey: state.identity.publicKey, pushToken: tokenForUnregister,
                    environment: state.environment, bundleID: state.bundleID,
                    issuedAt: UInt64(max(0, date.now.timeIntervalSince1970)))
                let signed = registration.signed(with: state.identity, domain: .unregister)
                return .run { [platform, registrationClient] send in
                    store.save(settings)
                    await platform.unregisterForRemoteNotifications()
                    if let url, let signed {
                        // Best effort: the server also expires registrations on its own.
                        try? await registrationClient.unregister(signed, url)
                    }
                    await send(.unregisterFinished)
                }

            case .unregisterFinished:
                return .none

            case let .hubChanged(host, port):
                state.hubHost = host
                state.hubPort = port
                guard state.enabled else { return .none }
                let settings = state.sharedSettings
                let store = state.storage.settings
                return .run { _ in store.save(settings) }

            case .appLaunched:
                // UNUserNotificationCenter returns the stored answer without prompting once the
                // user has already decided, so re-checking on every launch is free and catches a
                // permission revoked in Settings since the last run.
                let enabled = state.enabled
                if enabled { state.status = .awaitingPermission }
                let inbox = state.storage.inbox
                return .merge(
                    .run { [platform] send in
                        guard enabled else { return }
                        let granted = await platform.requestAuthorization()
                        await send(.permissionResolved(granted: granted))
                    },
                    .run { _ in try? inbox.prepare() },
                    .send(.drainInbox)
                )

            case .drainInbox:
                let inbox = state.storage.inbox
                return .run { send in
                    let packets = (try? inbox.drain()) ?? []
                    await send(.inboxDrained(packets))
                }

            case let .inboxDrained(packets):
                guard !packets.isEmpty else { return .none }
                return .send(.delegate(.inject(packets: packets)))

            case .delegate, .binding:
                return .none
            }
        }
    }
}
