# ReTiCAPush

Opt-in push wake-ups for a ReTiCA-based iOS messenger, against a push-capable Reticulum hub.

- `ReTiCAPushCore`: push payload decoding, the shared inbox, the proof builder, the msgpack
  registration wire (`RegistrationWire`) and the pure link-registration state machine
  (`RegistrationLinkFlow`), shared settings and storage locations.
- `ReTiCAPush`: the TCA `PushFeature` a host app scopes in. It emits
  `delegate(.sendRegistration(hub:path:data:))`; the app runs the link (see below) and answers
  with `registrationResponse`.
- `ReTiCAPushExtension`: `PushServiceHandler` for a Notification Service Extension.
- `docs/server-contract.md`: what a hub must do (registration over a Reticulum link, dormant
  interfaces, the push shape).

Design: the host app repo's `docs/superpowers/specs/2026-10-01-push-relay-design.md`.

## Integrating

- Build `PushStorage.appGroup("<group id>")` in both the app and the extension; pass it to
  `PushFeature.State` and to `PushServiceHandler.live(storage:)`.
- Override `pushPlatform` with the UIKit implementation when building the store; the package's
  `liveValue` only reports an issue.
- On `delegate(.sendRegistration)`, drive a `RegistrationLinkFlow`: feed it your endpoint's
  `pathLearned`, `linkEstablished`, `linkFailed`, `linkClosed`, `responseReceived` and
  `requestFailed` events plus a timeout, execute its commands (`requestPath`, `openLink`,
  `identify`, `sendRequest`, `closeLink`), and send `finished` back as `registrationResponse`.
- Execute each command list IN ORDER (`identify` before `sendRequest`): concatenate the endpoint
  sends, do not merge them, or the hub answers `not_identified`.
- Never forward `finished(.failure(.cancelled))` as a `registrationResponse`: a cancellation is
  caused by a newer attempt (or by disabling), and the newer attempt reports its own result.
  Forward every other failure as `RegistrationFailure(failure)`.
- `hubKnown` is whether your transport already has a REACHABLE path to the hub (ReTiCA: a learned
  entry whose interface is registered, not merely `learned[hub] != nil`). The host owns the
  attempt timeout (20 s is a good default) and feeds `.timedOut`.
- The hub refuses a registration link that did not arrive directly over its own spawned client
  connection (`not_direct`): open the link over the hub's TCP interface, only once that interface
  is connected, and never enable anything like RNS's `local_hops_delta` in the client's transport
  (every link would then look relayed and registration would always fail).
- The extension calls `handle(userInfo:)` and hands back the original content unless the verdict is `.suppress`, and always the original
  from `serviceExtensionTimeWillExpire`.
- `appLaunched` prepares the inbox directory and re-checks notification permission. A changed
  push hub takes effect on the next launch.
- Re-registration (the 24-hour rule) runs when a device token arrives, i.e. on launch; an app that
  stays alive for days re-registers at its next launch, which the hub's 30-day expiry tolerates.
- The Settings screen's hub field should send `setHubHex` on change, not bind `hubHex` directly:
  a `@Shared` binding writes the value without going through the reducer.
- **Close the hub TCP connection when the app goes to the background.** A suspended app's socket
  stays open from the hub's side (the kernel keeps answering keepalives and ACKing writes), so the
  hub keeps delivering into a socket nobody reads and never goes dormant: no pushes for as long as
  the socket survives, which was 2–15 minutes on cellular. A deliberate close while the process
  still runs makes the hub dormant at once; re-dial on foreground. (ReTiCA hosts: send
  `.endpoint(.tcpClient(.disconnect))` on the scene's `.background` phase; ReTiCA ≥ the
  2026-10-02 fix deregisters the interface on an explicit disconnect.)
- Push wake-ups deliver the message itself only for single-packet (OPPORTUNISTIC) senders. Link
  based senders (LXMF DIRECT — Sideband, NomadNet, Retichat) produce a pushed LINKREQUEST that
  nothing can answer in time; the banner is still useful as a wake, and a propagation node is
  what actually carries their message to a suspended client.
- Extension limits a hub author should know (the contract has the authoritative text, not edited
  here): IFAC-flagged packets are stashed but not proved by the extension; before the device's
  first unlock nothing is proved, only stashed; link requests are stashed and never answered from
  the extension.

### Banner suppression for blocked senders

The host writes its blocklist (lowercase hex `lxmf.delivery` hashes) with
`BlockedSenderStore.save` in the app-group suite. `PushServiceHandler.handle` returns a
`PushVerdict`: `.suppress` when every packet it could attribute came from a blocked sender,
`.deliverOriginal` otherwise, including on timeout, without an identity, or for link-based
pushes, which carry no readable sender. Attribution decrypts the packet with the identity's
static key and reads the LXMF source hash; nothing else is read and the signature is not
checked. The host returns empty notification content for `.suppress`, which hides the banner
only when it holds `com.apple.developer.usernotifications.filtering`.

Tests: `swift test --package-path .`
