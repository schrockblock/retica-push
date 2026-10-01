# ReTiCAPush

Opt-in push wake-ups for a ReTiCA-based iOS messenger, against a push-capable Reticulum hub.

- `ReTiCAPushCore`: payload decoding, shared inbox, proof builder, signed registration, HTTP client.
- `ReTiCAPush`: the TCA `PushFeature` a host app scopes in.
- `ReTiCAPushExtension`: `PushServiceHandler` for a Notification Service Extension.
- `docs/server-contract.md`: what a hub must do.

Design: the host app repo's `docs/superpowers/specs/2026-10-01-push-relay-design.md`.

Tests: `swift test --package-path .`
