# ReTiCA push hub — server contract (v1)

A push hub is a Reticulum transport node that can wake an iOS client with an Apple push when
the client's socket is down. The client (`ReTiCAPush`) never uploads messages: the hub already
sits on every path to the client, so it pushes the very bytes it would have written to the
client's socket. The client proves them back over a fresh socket, and the hub routes the proof
to the sender the standard way.

Everything here is normative for a hub a `ReTiCAPush` client can talk to.

## 1. Registration API

Two endpoints, same JSON body, same signing scheme, different domain string.

- `POST {base}/v1/registrations` — create or replace a registration.
- `DELETE {base}/v1/registrations` — remove it.

`{base}` is whatever the user typed as the registration URL, for example
`https://hub.example.net/push`. Trailing slashes are ignored.

### 1.1 Body

| key | type | notes |
|---|---|---|
| `v` | int | always `1` |
| `identity_public_key` | base64 | 64 bytes: X25519 public key ‖ Ed25519 public key, the Reticulum identity serialisation |
| `push_token` | hex | the APNs device token bytes, lowercase hex |
| `platform` | string | `"ios"` |
| `environment` | string | `"production"` or `"sandbox"` |
| `bundle_id` | string | the registering app's bundle identifier |
| `issued_at` | int | Unix seconds at signing time |
| `signature` | base64 | 64-byte Ed25519 signature over the signing bytes (§1.2) |

### 1.2 Signing bytes

Concatenate, with no separators:

1. the domain as UTF-8: `retica-push-register-v1` for POST, `retica-push-unregister-v1` for DELETE
2. the 64 public-key bytes
3. the push-token length as a big-endian UInt16, then the token bytes
4. the `platform` UTF-8 length as a UInt8, then the bytes
5. the `environment` UTF-8 length as a UInt8, then the bytes
6. the `bundle_id` UTF-8 length as a UInt8, then the bytes
7. `issued_at` as a big-endian UInt64

Sign with the Ed25519 half of the identity (the last 32 bytes of the private key). The signature
is the standard 64-byte Ed25519 signature.

### 1.3 Server rules

- Verify `signature` with the Ed25519 half of `identity_public_key`. Reject with 401 otherwise.
  **This check is mandatory.** Without it anyone can register their own token for someone else's
  destination and receive that person's wake-ups and encrypted packets.
- Reject with 400 when `issued_at` is more than 300 seconds from server time, when `v` is not 1,
  or when any field is missing or malformed.
- Derive the client's LXMF delivery destination hash yourself:
  `identity_hash = SHA-256(identity_public_key)[:16]`,
  `destination_hash = SHA-256(SHA-256("lxmf.delivery")[:10] ‖ identity_hash)[:16]`.
  This is `RNS.Destination.hash(identity, "lxmf", "delivery")`.
- POST stores `destination_hash → (push_token, environment, bundle_id, issued_at)`, replacing an
  existing entry for that hash, and answers 200 with
  `{"destination_hash": "<hex>", "expires_at": <unix seconds>}`.
  A registration expires 30 days after the last POST.
- DELETE removes the entry and the client's dormant interface (§2) and answers 204. An unknown
  hash also answers 204.
- An APNs `410 Unregistered` or `BadDeviceToken` response drops the entry and its dormant
  interface.
- The server never needs the client's private key, its messages, or its socket address.

## 2. Transport behaviour

The hub runs a Reticulum transport node. Its TCP server interface is the hub the client dials
(the same host and port the client has configured as its node connection).

- **Binding.** When an announce whose destination hash is a registered `destination_hash`
  arrives on a spawned client interface, that interface is bound to the registration. A later
  announce for the same hash on a different spawned interface rebinds to the new one and retires
  the old one, dormant or not.
- **Dormancy.** When a bound interface's socket closes, the interface stays attached to the
  transport, so the path table, the reverse table and the link table entries that reference it
  remain valid, and it becomes dormant. An unbound spawned interface behaves as stock: detached
  on close.
- **Pushing.** For every outgoing buffer the transport hands a dormant interface: if the
  packet's destination hash equals the bound `destination_hash` (this covers DATA and
  LINKREQUEST packets to the client's delivery destination), push the bytes **exactly as they
  would have hit the socket, after IFAC masking and before HDLC framing**. Drop any other buffer
  (announces, path requests, link packets addressed by link id, packets for other destinations),
  as the dead socket would have.
- **Proof return.** The client returns proofs on a fresh TCP connection that may never
  announce. Proofs must route by the reverse table regardless of ingress interface. Stock RNS
  does this.
- **Retries.** A sender retries a single-packet message every 10 s up to five times, each with a
  distinct packet hash, and its receipt for each attempt lives only 6 s plus 6 s per hop. Push
  every attempt. Use `apns-collapse-id` (§3) so the user sees one banner. A per-destination rate
  limit (suggested: 20 pushes per minute) protects the APNs quota.
- **Lifetime.** A dormant interface lives as long as its registration.

## 3. Push shape

Headers: `apns-push-type: alert`, `apns-priority: 10`, `apns-topic: <bundle_id>`,
`apns-collapse-id: <destination_hash hex>`. Send to the APNs environment the registration named.

```json
{
  "aps": {
    "alert": { "title": "New message" },
    "mutable-content": 1,
    "content-available": 1
  },
  "rns": {
    "v": 1,
    "packets": ["<base64 raw packet>", "..."]
  }
}
```

- `aps.alert.title` is fixed by the server and never carries sender or content information.
  The client's service extension never changes it.
- Each entry of `packets` is one raw Reticulum packet (at most 500 bytes), base64 without line
  breaks.
- Packets to one destination that arrive within 500 ms may be batched into one push: at most 8
  packets and 3500 bytes of base64 in total (the APNs payload limit is 4 KB).
- Pushes for different registrations are never batched.
- `mutable-content: 1` runs the client's service extension, which stashes the packets and
  proves them. `content-available: 1` additionally asks iOS for a best-effort background wake of
  the app, which ingests the packets sooner. Both are required.

## 4. What the client does with a push

For the hub author's mental model, not something the hub depends on:

1. The service extension decodes `rns.packets`, writes each packet to a shared inbox, signs an
   implicit proof (`Ed25519(packet_hash)` addressed to `packet_hash[:16]`) for every DATA packet
   addressed to the client's delivery hash, opens one TCP connection to the hub, writes the
   HDLC-framed proofs, closes. It never decrypts anything and never changes the notification.
2. The app, when it next runs (background wake, tap or launch), reconnects to the hub, announces,
   and feeds the inbox packets into its transport as if the socket had delivered them. That path
   decrypts, dedups and may send a second proof, which the sender ignores.

## 5. Reference implementation note

For the Python reference stack this is a custom `RNS.Interfaces.Interface` subclass: a
push-aware `TCPServerInterface` whose spawned interfaces implement binding and dormancy, with
`process_outgoing` routing to APNs for dormant ones, plus a small HTTP service for §1 and a
token-based APNs client. No change to RNS itself is needed. No code is part of this deliverable.
