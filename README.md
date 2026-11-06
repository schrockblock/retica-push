# ReTiCAPush

Push-notification wake-ups for iOS apps built on [ReTiCA](https://github.com/schrockblock/retica),
a Swift implementation of Reticulum and LXMF.

An iOS app that is not in the foreground is suspended within seconds, and its TCP socket to a
Reticulum node dies with it. Messages sent to the phone while it is suspended have nowhere to go
until the user opens the app again. ReTiCAPush lets a Reticulum transport node that the app
connects to (a "push hub") forward those packets through Apple Push Notification service (APNs),
still encrypted, so the phone shows a notification and can receive the message without the app
being open.

The hub is a separate program. Its wire contract is in
[docs/server-contract.md](docs/server-contract.md). The reference hub is `rns-push`
(github.com/schrockblock/rns-push), a Python package that runs on stock RNS.

## Contents

- [How it works](#how-it-works)
- [What each party can see](#what-each-party-can-see)
- [Products](#products)
- [Requirements](#requirements)
- [Integrating into an app](#integrating-into-an-app)
- [Running your own hub](#running-your-own-hub)
- [Tests](#tests)
- [Known limits](#known-limits)

## How it works

1. **Registration, over Reticulum.** The hub owns an `rnspush.registration` destination. When push
   is on and the app has an APNs device token, the app opens a Reticulum link to that destination
   over its direct TCP connection to the hub, identifies on the link with its own identity, and
   sends a `/register` request carrying the device token, the APNs environment and the app's bundle
   identifier. The hub derives the app's `lxmf.delivery` destination hash from the identified
   identity and answers with it, so the app can check it. There is no HTTP API and no account: the
   link's identification is the authentication. The app re-registers when its token changes or the
   last registration is more than 24 hours old; the hub expires a registration after 30 days.
   Turning push off sends `/unregister`.

2. **Dormant interface on the hub.** The hub's TCP connection to the app is bound to that
   registration. When the app's socket closes, the hub keeps the connection's interface attached to
   its transport as a dormant interface, so its path, reverse and link table entries stay valid.
   Anything the transport would have written to that socket is now a candidate for a push.

3. **The push carries raw packets.** For every packet the transport hands the dormant interface
   whose destination is the registered destination (DATA and LINKREQUEST packets), the hub sends an
   APNs push containing the packet bytes exactly as they would have gone down the socket, base64
   encoded in an `rns` block. The alert title is fixed by the hub ("New message") and never names
   the sender or contains message text. Up to 8 packets that arrive within 500 ms may share one push.

4. **The Notification Service Extension stashes and proves.** Because the push has
   `mutable-content: 1`, iOS runs the app's Notification Service Extension. `PushServiceHandler`
   decodes the packets, writes each one to an inbox directory in the shared app-group container,
   loads the identity from the shared Keychain, signs a Reticulum delivery proof for each DATA
   packet addressed to the app's delivery destination, and sends the proofs to the hub over one
   short TCP connection. The hub routes each proof back to the sender, whose message is then marked
   delivered. The extension hands back the notification unchanged (or empty, see blocked senders
   below).

5. **The app drains the inbox.** When the app next runs (a `content-available` background wake, a
   tap on the notification, or a normal launch), `PushFeature` drains the inbox and hands the
   packets to the host app, which feeds them into its ReTiCA transport as if its socket had just
   read them. They are then decrypted, deduplicated and delivered by the normal receive path.

6. **"Propagated" pushes.** A hub that also runs an LXMF propagation node can send a push with
   `"kind": "propagated"` in the `rns` block and no packets, meaning "a message for you is waiting
   on the propagation node". `PushPayload.isPropagated(_:)` recognises it; the app's response is to
   sync from its propagation node. The extension treats it as an ordinary push with nothing to
   stash, and the banner shows.

7. **Blocked senders.** The host app can mirror its blocklist (sender `lxmf.delivery` hashes) into
   the app group with `BlockedSenderStore`. For each push, the extension tries to attribute every
   packet to a sender by decrypting it and reading the LXMF source hash. If every packet in the push
   was attributed and every sender is blocked, `handle` returns `.suppress` and the host returns
   empty notification content. iOS only hides the notification for empty content if the extension
   holds the `com.apple.developer.usernotifications.filtering` entitlement, which Apple grants on
   request. Without it the original banner shows anyway. Any packet that cannot be attributed (a
   link request, a ratchet-encrypted packet, anything malformed) means the banner is shown.

## What each party can see

**The hub** stores, per registration: the app's identity public key (and so its `lxmf.delivery`
hash), the APNs device token, the APNs environment, the bundle identifier and the registration
time. As a Reticulum transport node it sees what any transport node on the path sees: packet
headers (destination hash, packet type), sizes, timing, and the IP address the app connects from,
including the short connection the extension opens to deliver proofs. It cannot read message
content or the sender: LXMF messages to a single destination are encrypted to the recipient's
identity, and the sender's address is inside the encrypted part. It never receives the app's
private key. The hub does learn that a given Reticulum destination belongs to a given APNs device
token and app, and when messages for it arrive.

**Apple** receives every push, so it sees the device token, the bundle identifier, the fixed alert
title, the timing, and the base64 packets. The packets are the same encrypted bytes the hub would
have written to the socket, so Apple cannot read content or the sender either. Their headers are
not encrypted, though, and the hub sets `apns-collapse-id` to the destination hash in hex, so Apple
can link a Reticulum destination hash to a device.

Neither the hub nor Apple can decrypt what they relay, but either could keep it. Packets encrypted
to an identity's long-term key (the case for ReTiCA identities, which publish no ratchets) can be
decrypted later by anyone who holds both the stored packets and that identity's private key.

**The Notification Service Extension** runs on the device with the app's identity, read from the
shared Keychain, so it could decrypt everything; what it actually does is limited:

- It writes the raw packets to the inbox unchanged. Inbox files carry no iOS file protection,
  because a push can arrive before the device's first unlock; they hold the same encrypted bytes
  that crossed the network.
- It signs a delivery proof (Ed25519 over the packet hash) for each DATA packet to the app's
  delivery destination. Proofs are what any Reticulum receiver sends.
- Only when the blocklist is non-empty, it decrypts each packet to read the LXMF source hash, and
  nothing else. The message content is not read and the message signature is not checked. Nothing
  but the `.deliverOriginal` / `.suppress` verdict leaves `PushServiceHandler`.
- It never rewrites the notification text. The host returns either the original content or, for
  `.suppress`, empty content.

## Products

| Product | Target type | What it contains | Linked by |
|---|---|---|---|
| `ReTiCAPushCore` | Plain Swift, no TCA | `PushPayload` (decode the `rns` block, `isPropagated`), `PushInbox`, `PushStorage`, `SharedPushSettings`, `BlockedSenderStore`, `BlockedSenderFilter`, `ProofBuilder`, `RegistrationWire` (msgpack request and response bodies), `RegistrationLinkFlow` (the registration state machine), `Identity.lxmfDeliveryHash` | Both, through the products below |
| `ReTiCAPush` | TCA | `PushFeature` (the push toggle, permission, device token, registration lifecycle, inbox drain) and the `PushPlatform` dependency | The app target |
| `ReTiCAPushExtension` | No TCA | `PushServiceHandler`, `PushVerdict`, `ProofFrameSender`, `KeychainIdentityLoader` | The Notification Service Extension target |

`ReTiCAPush` and `ReTiCAPushExtension` both re-export `ReTiCAPushCore`. The extension product
deliberately avoids The Composable Architecture, so the extension does not link it; it depends on
`ReTiCA` and `ReTiCAKeychain` only.

## Requirements

- iOS 17 or macOS 14.
- Swift tools 6.0, Swift 6 language mode. ReTiCA's own manifest currently asks for Swift tools 6.3.
- [swift-composable-architecture](https://github.com/pointfreeco/swift-composable-architecture)
  1.15.0 or later (fetched by SwiftPM).
- **ReTiCA as a sibling checkout.** `Package.swift` depends on ReTiCA by local path, `../ReTiCA`.
  Clone [ReTiCA](https://github.com/schrockblock/retica) into a directory named `ReTiCA` next to
  this package:

  ```
  some-dir/
    ReTiCA/        # git clone https://github.com/schrockblock/retica ReTiCA
    ReTiCAPush/    # this package
  ```

  ReTiCA has sibling path dependencies of its own (currently `../FCB` and `../MeshtasticKit`); see
  its README.

## Integrating into an app

The steps below follow the way ReTiCaMsgr, the app this package was written for, uses it. The
identifiers (`group.com.example.messenger`, `ABCDE12345`, and so on) are placeholders.

### 1. Targets and dependencies

- App target: link `ReTiCAPush` (and the ReTiCA products your app already uses).
- Notification Service Extension target: link `ReTiCAPushExtension` only.

### 2. App group and shared Keychain

The app and the extension share two things:

- **An app group**, for the inbox directory and two small values in the group's `UserDefaults`
  suite: the shared settings (hub host and port, Keychain location, last registration) and the
  blocklist. Build the storage the same way in both processes:

  ```swift
  let storage = PushStorage.appGroup("group.com.example.messenger") // nil without the entitlement
  ```

- **A Keychain access group**, for the Reticulum identity. The extension needs the private key to
  sign proofs and must read the same item the app uses. Store the app's identity with ReTiCA's
  `IdentityKeychain` at a location with a non-empty, team-prefixed access group, for example
  `IdentityKeychain.Location(service: "reticulum.identity", accessGroup:
  "ABCDE12345.com.example.reticulum.identity")`, and pass the same service and access group to
  `PushFeature.State`. `PushFeature` writes them into the shared settings, and the extension reads
  the identity with `IdentityKeychain.load`, which never creates one. ReTiCA's Keychain items are
  readable after first unlock.

### 3. Entitlements and Info.plist

App target entitlements:

```xml
<key>aps-environment</key>
<string>development</string>           <!-- production for TestFlight and App Store builds -->
<key>com.apple.security.application-groups</key>
<array>
    <string>group.com.example.messenger</string>
</array>
<key>keychain-access-groups</key>
<array>
    <string>$(AppIdentifierPrefix)com.example.reticulum.identity</string>
</array>
```

App `Info.plist`: add `remote-notification` to `UIBackgroundModes`, so a `content-available`
push can wake the app.

Extension entitlements: the same `com.apple.security.application-groups` and
`keychain-access-groups` values. Add the filtering entitlement only once Apple has granted it to
your team; until then a provisioning profile cannot carry it, and suppression has no visible effect:

```xml
<key>com.apple.developer.usernotifications.filtering</key>
<true/>
```

Extension `Info.plist`:

```xml
<key>NSExtension</key>
<dict>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.usernotifications.service</string>
    <key>NSExtensionPrincipalClass</key>
    <string>$(PRODUCT_MODULE_NAME).NotificationService</string>
</dict>
```

The `environment` you register with (`.sandbox` or `.production`) must match the
`aps-environment` the build was signed with, or APNs rejects the hub's pushes.

### 4. The Notification Service Extension

```swift
import Foundation
import UserNotifications
import ReTiCAPushExtension

final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var original: UNNotificationContent?
    private var work: Task<Void, Never>?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        self.original = request.content
        guard let storage = PushStorage.appGroup("group.com.example.messenger") else {
            finish(.deliverOriginal)
            return
        }
        let handler = PushServiceHandler.live(storage: storage)
        // `[AnyHashable: Any]` is not Sendable. `handle` decodes it before its first suspension
        // and nothing else touches it.
        nonisolated(unsafe) let userInfo = request.content.userInfo
        work = Task {
            let verdict = await handler.handle(userInfo: userInfo)
            self.finish(verdict)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        work?.cancel()
        finish(.deliverOriginal)
    }

    /// Calls the content handler exactly once: the normal path and the expiry callback can race.
    private func finish(_ verdict: PushVerdict) {
        lock.lock()
        defer { lock.unlock() }
        guard let contentHandler, let original else { return }
        self.contentHandler = nil
        switch verdict {
        case .deliverOriginal: contentHandler(original)
        case .suppress: contentHandler(UNNotificationContent())
        }
    }
}
```

`handle(userInfo:)` always returns within its deadline (20 seconds by default), well inside the
time iOS gives an extension. A push that does not decode returns `.deliverOriginal` at once.

### 5. The app: `PushPlatform`

`PushFeature` asks for notification permission and the device token through a `PushPlatform`
dependency. The package's live value is a placeholder that reports an issue and behaves as if
permission were denied, so supply the UIKit version when you build your store:

```swift
extension PushPlatform {
    static let uiKit = PushPlatform(
        requestAuthorization: {
            (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        },
        registerForRemoteNotifications: {
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
        },
        unregisterForRemoteNotifications: {
            await MainActor.run { UIApplication.shared.unregisterForRemoteNotifications() }
        })
}

// Store(initialState: ...) { AppFeature() } withDependencies: { $0.pushPlatform = .uiKit }
```

### 6. The app: `PushFeature` state

```swift
PushFeature.State(
    destinationHash: identity.lxmfDeliveryHash,
    aspects: nil,                       // nil means lxmf.delivery
    appName: "Messenger",               // used in the "Notifications are off for ..." text
    bundleID: Bundle.main.bundleIdentifier ?? "",
    environment: .sandbox,              // .production for TestFlight and App Store builds
    storage: PushStorage.appGroup("group.com.example.messenger") ?? .temporary(),
    keychainService: "reticulum.identity",
    keychainAccessGroup: "ABCDE12345.com.example.reticulum.identity")
```

Use this initializer. The shorter `init(identity:bundleID:environment:storage:keychainService:keychainAccessGroup:)`
hard-codes ReTiCaMsgr's app name.

Two fields persist in the app's standard `UserDefaults` through `@Shared(.appStorage)`: `enabled`
(key `pushEnabled`, default `true`, so the first launch asks for permission) and `hubHex` (key
`pushHubHex`, the hub's registration destination hash as 32 hex characters).

### 7. The app: actions to send

| When | Send |
|---|---|
| Every launch | `.appLaunched`: re-checks permission (no prompt once the user has answered), prepares the inbox directory, drains the inbox |
| `didRegisterForRemoteNotificationsWithDeviceToken` | `.deviceTokenReceived(token)` |
| `didFailToRegisterForRemoteNotificationsWithError` | `.deviceTokenFailed(error.localizedDescription)` |
| A Settings toggle | `.setEnabled(Bool)` |
| The hub's TCP host or port changes, and once at launch | `.hubChanged(host:port:)`: this is where the extension sends proofs |
| The hub destination field changes | `.setHubHex(String)`, not a binding to `hubHex`, which would skip the reducer |
| A background wake, a notification tap, or a foreground | `.drainInbox`, after re-dialling the hub |

`PushFeature.State.status.displayText` is a ready-made status line for a Settings screen.

### 8. The app: delegate actions

`PushFeature` never touches ReTiCA's node. It asks the host through two delegate actions:

- `.delegate(.inject(packets:))`: feed each packet to your transport as if it had been read from
  the hub's socket, for example `.transport(.received(hubInterfaceID, raw))` on ReTiCA's
  `TransportEndpoint`. Do this only once your `lxmf.delivery` destination is registered with the
  endpoint: ReTiCA records a packet hash before it looks for the local destination, so a packet
  injected too early is dropped and never accepted again. Until then, put the packets back with
  `storage.inbox.append(_:)`.
- `.delegate(.sendRegistration(hub:path:data:))`: run one registration attempt over a link to
  the hub. Drive a `RegistrationLinkFlow` with your endpoint's events and execute the commands it
  returns, then answer with `.registrationResponse`.

A host reducer that composes ReTiCA's `TransportEndpoint` with `PushFeature` can do it like this:

```swift
@Reducer
struct HostFeature {
    @ObservableState
    struct State: Equatable {
        var identity: Identity
        var endpoint: TransportEndpoint.State
        var push: PushFeature.State
        var registration = RegistrationLinkFlow()
        /// The interface id of the TCP connection to the push hub.
        var hubInterface: InterfaceID
    }

    enum Action {
        case endpoint(TransportEndpoint.Action)
        case push(PushFeature.Action)
        case registrationTimedOut
    }

    enum CancelID { case registrationTimeout }

    @Dependency(\.continuousClock) var clock

    var body: some ReducerOf<Self> {
        Scope(state: \.endpoint, action: \.endpoint) { TransportEndpoint() }
        Scope(state: \.push, action: \.push) { PushFeature() }
        Reduce { state, action in
            switch action {
            case let .push(.delegate(.inject(packets))):
                // Feed each stashed packet to the transport as if the hub socket had delivered it.
                // Only once your lxmf.delivery destination is registered with the endpoint.
                return .merge(packets.map { raw in
                    .send(.endpoint(.transport(.received(state.hubInterface, raw))))
                })
            default:
                break
            }

            // Translate endpoint delegates into RegistrationLinkFlow events.
            let event: RegistrationLinkFlow.Event
            switch action {
            case let .push(.delegate(.sendRegistration(hub, path, data))):
                let known = state.endpoint.transport.reachableLearned(hub) != nil
                event = .start(hub: hub, path: path, data: data, hubKnown: known)
            case let .endpoint(.delegate(.pathLearned(hash, _))):
                event = .pathLearned(hash)
            case let .endpoint(.delegate(.linkEstablished(linkID, hash))):
                event = .linkEstablished(linkID: linkID, destinationHash: hash)
            case let .endpoint(.delegate(.linkFailed(hash, _))):
                event = .linkFailed(destinationHash: hash)
            case let .endpoint(.delegate(.linkClosed(linkID, _))):
                event = .linkClosed(linkID: linkID)
            case let .endpoint(.delegate(.responseReceived(linkID, _, data))):
                event = .responseReceived(linkID: linkID, data: data)
            case let .endpoint(.delegate(.requestFailed(linkID, _))):
                event = .requestFailed(linkID: linkID)
            case .registrationTimedOut:
                event = .timedOut
            default:
                return .none
            }

            var effects: [Effect<Action>] = []
            if case .start = event {
                effects.append(.run { [clock] send in
                    try await clock.sleep(for: .seconds(20))
                    await send(.registrationTimedOut)
                }
                .cancellable(id: CancelID.registrationTimeout, cancelInFlight: true))
            }
            // Run the commands IN ORDER: `identify` must reach the hub before `sendRequest`.
            var ordered: [Effect<Action>] = []
            for command in state.registration.handle(event) {
                switch command {
                case let .requestPath(hub):
                    ordered.append(.send(.endpoint(.requestPath(destinationHash: hub))))
                case let .openLink(hub):
                    ordered.append(.send(.endpoint(.openLink(destinationHash: hub))))
                case let .identify(linkID):
                    ordered.append(.send(.endpoint(.identifyOverLink(linkID: linkID, identity: state.identity))))
                case let .sendRequest(linkID, path, data):
                    ordered.append(.send(.endpoint(.sendRequestOverLink(linkID: linkID, path: path, data: data))))
                case let .closeLink(linkID):
                    ordered.append(.send(.endpoint(.closeLink(linkID: linkID))))
                case .finished(.failure(.cancelled)):
                    // A newer attempt replaced this one and reports its own result.
                    break
                case let .finished(.success(data)):
                    ordered.append(.cancel(id: CancelID.registrationTimeout))
                    ordered.append(.send(.push(.registrationResponse(.success(data)))))
                case let .finished(.failure(failure)):
                    ordered.append(.cancel(id: CancelID.registrationTimeout))
                    ordered.append(.send(.push(.registrationResponse(.failure(RegistrationFailure(failure))))))
                }
            }
            if !ordered.isEmpty { effects.append(.concatenate(ordered)) }
            return .merge(effects)
        }
    }
}
```

Rules the sketch follows, each of which caused a real failure when broken:

- Execute each command list in order (`.concatenate`, not `.merge`). If `sendRequest` overtakes
  `identify`, the hub answers `not_identified`.
- Never forward `finished(.failure(.cancelled))`. A cancellation comes from a newer attempt (or
  from turning push off), and the newer attempt reports its own result. Forward every other
  failure as `RegistrationFailure(failure)`, which carries the Settings wording.
- `hubKnown` means the transport has a *reachable* path to the hub: a learned entry whose interface
  is currently registered (`reachableLearned`), not merely an entry in `learned`.
- The host owns the timeout. 20 seconds works.
- Start the attempt only once the TCP connection to the hub is up. ReTiCaMsgr holds a
  `sendRegistration` that arrives before then and replays it when the interface connects.
- The link must reach the hub directly over the app's own TCP connection to it. The hub refuses a
  registration link that was relayed by another node (`not_direct`), so never enable anything like
  RNS's `local_hops_delta` in the client's transport.

### 9. The app: background, wake and tap

- **Close the hub's TCP connection when the app goes to the background.** A suspended app's socket
  stays open from the hub's side (the kernel keeps acknowledging), so the hub keeps writing into a
  socket nobody reads and never goes dormant: no pushes until the socket times out, which was 2 to
  15 minutes on cellular. A deliberate close while the process still runs makes the hub's interface
  dormant at once. Re-dial when the app comes back. With ReTiCA, send the TCP client's
  `.disconnect` on the scene's `.background` phase.
- After reconnecting, the app's ordinary `lxmf.delivery` announce re-binds the new connection on
  the hub; no re-registration is needed.
- In `application(_:didReceiveRemoteNotification:)` (the `content-available` wake), append the
  decoded packets to the inbox (idempotent, in case the extension was killed before writing), re-dial
  the hub, and send `.drainInbox`.
- In `userNotificationCenter(_:willPresent:)` with the app in front, do the same and return `[]`
  to hide the banner; if `PushPayload.isPropagated(userInfo)` is true, sync from your propagation
  node.
- On a notification tap, stash and drain the same way.

```swift
for raw in (try? PushPayload.decode(userInfo)) ?? [] { _ = try? storage.inbox.append(raw) }
store.send(.push(.drainInbox))
```

### 10. The app: blocklist

Write the blocklist whenever it changes and at launch, as lowercase hex `lxmf.delivery` hashes:

```swift
storage.blockedSenders.save(blockedDeliveryHashes)   // Set<String>
```

The extension reads it once per push.

## Running your own hub

[docs/server-contract.md](docs/server-contract.md) is the specification a hub must meet:
the `rnspush.registration` destination and its `/register` and `/unregister` requests, binding and
dormancy of spawned TCP interfaces, proof return over a fresh connection, and the APNs payload
shape. You need an APNs authentication key for the team that signs the app, and the hub only
accepts bundle identifiers on its allow-list.

The reference implementation is `rns-push` (github.com/schrockblock/rns-push): a pip package plus
a one-line interface shim in the Reticulum config's `interfaces/` directory, running on stock RNS.

The contract document has not yet caught up with three things the client already supports:

- An optional `aspects` array in the `/register` and `/unregister` request data, naming a
  destination other than `lxmf.delivery` (for example `["nbhd", "sync"]`). `PushFeature` sends it
  when `State.aspects` is set to anything other than `["lxmf", "delivery"]`.
- The `"kind": "propagated"` marker described above.
- Background pushes (`content-available` only, no alert, no `mutable-content`). The reference hub
  sends link requests this way. The extension does not run for them; the app's
  `didReceiveRemoteNotification` stashes their packets.

## Tests

```
swift test
```

Run from the package directory, with ReTiCA checked out beside it. The tests use Swift Testing and
need no outside network; `ProofFrameSenderTests` opens a local TCP listener and connects to it over
127.0.0.1.

## Known limits

- **Only single-packet senders are delivered by the push itself.** An LXMF message sent
  opportunistically (one packet) arrives in the push and is proved from the extension. A sender
  that uses a link (LXMF direct delivery, which Sideband, NomadNet and Retichat use, and any
  message too large for one packet) produces a pushed LINKREQUEST, which nothing on the phone can
  answer in time. The push still works as a wake-up, but the message reaches a suspended phone only
  through a propagation node, or once the app is running and the sender retries.
- **A propagated push carries no message.** The app has to sync from its propagation node. If the
  app's configured propagation node is not the one the hub watches, the sync can come back empty.
- **Banner suppression is best effort.** It needs the filtering entitlement. It cannot attribute
  link requests or ratchet-encrypted packets (ReTiCA identities publish no ratchets, but a
  packet encrypted to a ratchet key from elsewhere cannot be opened with the static key), and one
  unattributable packet in a batched push shows the banner. Propagated pushes always show. The
  source hash is not authenticated, so a forged packet could hide a banner; it can do nothing else.
- **Before first unlock** the Keychain item is unreadable: packets are stashed but not proved, and
  the original notification is delivered. The app proves them when it drains the inbox.
- **IFAC-flagged packets** are stashed but not proved by the extension, which has no interface key.
  The hub's push interfaces do not use IFAC.
- **Proofs from the extension cover `lxmf.delivery` only.** A registration for other aspects gets
  its packets stashed, but the extension proves only packets addressed to the identity's
  `lxmf.delivery` hash.
- **Hub restarts and path expiry.** Dormancy does not survive a hub restart, and the hub forgets
  the app's path after a week without an announce. Pushes resume the next time the app connects
  and announces.
- **Re-registration happens only when a token arrives**, which in practice is at launch. An app
  that stays alive for days re-registers at its next launch, inside the hub's 30-day expiry.
- **A changed hub takes effect on the next launch**, unless the host re-sends the device token
  itself (ReTiCaMsgr does when the field becomes a valid hub and a token is in hand).
- **The inbox holds at most 256 packets**; the oldest are dropped beyond that.
- **One push may batch up to 8 packets** of at most 500 bytes each (`Packet.mtu`); larger pushes
  are rejected by `PushPayload.decode` and the original notification is delivered.
