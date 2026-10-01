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
- The extension calls `handle(userInfo:)` and ALWAYS hands back the original content, also from
  `serviceExtensionTimeWillExpire`.
- `appLaunched` prepares the inbox directory and re-checks notification permission. A changed
  push hub takes effect on the next launch.
- The Settings screen's hub field should send `setHubHex` on change, not bind `hubHex` directly:
  a `@Shared` binding writes the value without going through the reducer.

Tests: `swift test --package-path .`
