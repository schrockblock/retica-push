import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCAPushCore

/// Why a registration request over the hub link failed, as shown in Settings.
public struct RegistrationFailure: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

public extension RegistrationFailure {
    /// The Settings wording for each way a link attempt can end, so every host shows the same text.
    init(_ failure: RegistrationLinkFlow.Failure) {
        switch failure {
        case .hubUnreachable: self.init("Push hub not reachable")
        case .linkFailed: self.init("Push hub link failed")
        case .requestFailed: self.init("Push hub did not answer")
        case .timedOut: self.init("Push hub timed out")
        case .cancelled: self.init("Registration cancelled")
        }
    }
}

/// Opt-in push wake-ups (spec §1). Owns the toggle, the APNs token and the registration
/// lifecycle, and drains the shared inbox into `delegate(.inject)` for the host app to feed its
/// transport. Never touches ReTiCA's node.
@Reducer
public struct PushFeature {
    public static let invalidHubText = "Invalid push hub address"
    public static let wrongDestinationText = "Hub registered the wrong destination"
    public static let invalidResponseText = "Hub sent an invalid response"
    public static let hubChangedText = "Push hub changed; registers on next launch"
    /// A registration is skipped when the same token was registered more recently than this.
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

        public var destinationHash: Data
        public var aspects: [String]?
        public var appName: String
        public var bundleID: String
        public var environment: PushEnvironment
        public var storage: PushStorage
        public var keychainService: String
        public var keychainAccessGroup: String?

        /// On by default, so a first launch asks for permission; only a stored choice (the user
        /// switching it off, or the host turning it off with its push node) keeps it off.
        @Shared(.appStorage("pushEnabled")) public var enabled: Bool = true
        /// The push hub's registration destination hash, 32 hex characters (contract §1.1).
        @Shared(.appStorage("pushHubHex")) public var hubHex: String = ""

        /// Mirrored from the host app's hub settings by `hubChanged`.
        public var hubHost: String = ""
        public var hubPort: Int = 0
        public var deviceToken: Data? = nil
        public var status: Status = .idle
        public var lastRegistration: RegistrationRecord? = nil

        /// ReTiCaMsgr's registration: `lxmf.delivery` of its identity, which the hub assumes when
        /// no aspects are sent.
        public init(identity: Identity, bundleID: String, environment: PushEnvironment,
                    storage: PushStorage, keychainService: String, keychainAccessGroup: String?) {
            self.init(destinationHash: identity.lxmfDeliveryHash, aspects: nil, appName: "ReTiCaMsgr",
                      bundleID: bundleID, environment: environment, storage: storage,
                      keychainService: keychainService, keychainAccessGroup: keychainAccessGroup)
        }

        /// Any destination of the app's identity: `aspects` names it for the hub, which derives the
        /// hash itself and answers with it; a response naming another hash is refused.
        public init(destinationHash: Data, aspects: [String]?, appName: String, bundleID: String,
                    environment: PushEnvironment, storage: PushStorage, keychainService: String,
                    keychainAccessGroup: String?) {
            self.destinationHash = destinationHash
            self.aspects = aspects
            self.appName = appName
            self.bundleID = bundleID
            self.environment = environment
            self.storage = storage
            self.keychainService = keychainService
            self.keychainAccessGroup = keychainAccessGroup
            self.lastRegistration = storage.settings.load().lastRegistration
        }

        public var deniedText: String { "Notifications are off for \(appName) in Settings" }

        /// What the extension reads. Built from state so every writer agrees.
        var sharedSettings: SharedPushSettings {
            SharedPushSettings(hubHost: hubHost, hubPort: hubPort, keychainService: keychainService,
                               keychainAccessGroup: keychainAccessGroup, lastRegistration: lastRegistration)
        }
    }

    public enum Action: Equatable, BindableAction {
        case setEnabled(Bool)
        case hubChanged(host: String, port: Int)
        /// The Settings field. Explicit, not a binding: `@Shared` bindings write the value
        /// directly and never reach the reducer, and this change has a side effect.
        case setHubHex(String)
        case appLaunched
        case permissionResolved(granted: Bool)
        case deviceTokenReceived(Data)
        case deviceTokenFailed(String)
        case registrationResponse(Result<Data, RegistrationFailure>)
        case unregisterFinished
        case drainInbox
        case inboxDrained([Data])
        case delegate(Delegate)
        case binding(BindingAction<State>)

        @CasePathable
        public enum Delegate: Equatable {
            case inject(packets: [Data])
            /// The host app should drive a `RegistrationLinkFlow` against `hub` and answer with
            /// `registrationResponse`.
            case sendRegistration(hub: Data, path: String, data: Data)
        }
    }

    @Dependency(\.pushPlatform) var platform
    @Dependency(\.date) var date

    public init() {}

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
                state.status = .failed(state.deniedText)
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
                guard let hub = Data(pushHex: state.hubHex), hub.count == 16 else {
                    state.status = .failed(Self.invalidHubText)
                    return .none
                }
                state.status = .registering
                let request = RegistrationWire.registerRequest(token: token, environment: state.environment,
                                                               bundleID: state.bundleID, aspects: state.aspects)
                return .send(.delegate(.sendRegistration(hub: hub, path: RegistrationWire.registerPath, data: request)))

            case let .deviceTokenFailed(reason):
                guard state.enabled else { return .none }
                state.status = .failed(reason)
                return .none

            case let .registrationResponse(.success(data)):
                // Only an attempt in flight has a result to record: a late or stale response (an
                // /unregister answered after re-enabling, a superseded attempt) is ignored.
                guard state.enabled, state.status == .registering else { return .none }
                switch RegistrationWire.decodeResponse(data) {
                case let .registered(destinationHash, _):
                    guard destinationHash == state.destinationHash else {
                        state.status = .failed(Self.wrongDestinationText)
                        return .none
                    }
                    state.status = .registered(date.now)
                    if let token = state.deviceToken {
                        state.lastRegistration = RegistrationRecord(tokenHex: token.pushHex, registeredAt: date.now)
                    }
                    let settings = state.sharedSettings
                    let store = state.storage.settings
                    return .run { _ in store.save(settings) }
                case let .refused(code):
                    state.status = .failed("Hub refused: \(code)")
                    return .none
                case .unregistered, .malformed:
                    state.status = .failed(Self.invalidResponseText)
                    return .none
                }

            case let .registrationResponse(.failure(failure)):
                // Only an attempt in flight has a result to record: a late or stale response (an
                // /unregister answered after re-enabling, a superseded attempt) is ignored.
                guard state.enabled, state.status == .registering else { return .none }
                state.status = .failed(failure.message)
                return .none

            case .setEnabled(false):
                state.$enabled.withLock { $0 = false }
                state.deviceToken = nil
                state.status = .idle
                state.lastRegistration = nil
                let settings = state.sharedSettings
                let store = state.storage.settings
                let hub = Data(pushHex: state.hubHex).flatMap { $0.count == 16 ? $0 : nil }
                var effects: [Effect<Action>] = [
                    .run { [platform] _ in
                        store.save(settings)
                        await platform.unregisterForRemoteNotifications()
                    },
                ]
                if let hub {
                    // Best effort: the hub also expires registrations on its own.
                    effects.append(.send(.delegate(.sendRegistration(hub: hub, path: RegistrationWire.unregisterPath,
                                                                     data: RegistrationWire.unregisterRequest(aspects: state.aspects)))))
                }
                effects.append(.send(.unregisterFinished))
                return .merge(effects)

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

            case let .setHubHex(hex):
                let hex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
                guard hex != state.hubHex else { return .none }
                state.$hubHex.withLock { $0 = hex }
                // A different hub knows nothing about this device: forget the old registration so
                // the next launch registers again. No network here, the field changes per keystroke.
                guard state.enabled else { return .none }
                state.lastRegistration = nil
                switch state.status {
                case .registering, .registered:
                    // Drop the in-flight (or just-finished) attempt: it was against the old hub,
                    // and `registrationResponse`'s `.registering` guard discards its result.
                    state.status = .failed(Self.hubChangedText)
                default:
                    break
                }
                let settings = state.sharedSettings
                let store = state.storage.settings
                return .run { _ in store.save(settings) }

            case .delegate, .binding:
                return .none
            }
        }
    }
}
