import Foundation
import ReTiCA
import ReTiCAPushCore

/// What the host does with the notification once `handle` returns (spec 2026-10-15 §4).
/// `.suppress` means every packet that could be attributed came from a blocked sender; with the
/// `com.apple.developer.usernotifications.filtering` entitlement the host returns empty content
/// and no banner shows. Without it iOS shows the original either way.
public enum PushVerdict: Equatable, Sendable {
    case deliverOriginal
    case suppress
}

/// What the Notification Service Extension does with a push (push spec §1, block spec §4):
/// stash every packet in the shared inbox, decide whether the banner should show, sign a proof
/// for each DATA packet addressed to our delivery hash, write the proofs to the hub over one
/// short connection. The only decryption is `BlockedSenderFilter`'s read of the sender hash,
/// for the verdict; the content is never read and nothing but the verdict leaves this type.
///
/// `handle` itself always returns by `deadline`: `process` runs unstructured and is raced against
/// a timer, so a non-cooperative wait inside `sendFrames` (e.g. an `NWConnection` callback) cannot
/// hold the call past the deadline — it is simply abandoned, to die with the extension process once
/// the content handler has fired. The verdict is decided before that wait and parked in a locked
/// box, so a late sender never costs the verdict. A locked Keychain (before first unlock) means the
/// packets are stashed, nothing is proved and the original is delivered.
public struct PushServiceHandler: Sendable {
    public let inbox: PushInbox
    public let settings: SharedPushSettings
    /// Lowercase hex lxmf.delivery hashes from `BlockedSenderStore`.
    public let blockedSenders: Set<String>
    public let loadIdentity: @Sendable () -> Identity?
    /// The host's own ratchet ring (X25519 private keys, newest first) for a delivery hash, or nil
    /// when it has none or cannot read it. READ-ONLY: the extension never saves or rotates a ring;
    /// only the app does. Used only to attribute packets for the verdict.
    public let loadRatchets: @Sendable (_ deliveryHash: Data) -> [Data]?
    public let sendFrames: @Sendable (_ host: String, _ port: Int, _ frames: [Data]) async -> Void
    public let deadline: Duration

    public init(inbox: PushInbox, settings: SharedPushSettings,
                blockedSenders: Set<String> = [],
                loadIdentity: @escaping @Sendable () -> Identity?,
                loadRatchets: @escaping @Sendable (_ deliveryHash: Data) -> [Data]? = { _ in nil },
                sendFrames: @escaping @Sendable (_ host: String, _ port: Int, _ frames: [Data]) async -> Void,
                deadline: Duration = .seconds(20)) {
        self.inbox = inbox
        self.settings = settings
        self.blockedSenders = Set(blockedSenders.map { $0.lowercased() })
        self.loadIdentity = loadIdentity
        self.loadRatchets = loadRatchets
        self.sendFrames = sendFrames
        self.deadline = deadline
    }

    /// The real thing: inbox, settings and blocklist from `storage`, identity from the shared
    /// Keychain, proofs over `ProofFrameSender`. A host with its own ratchets passes
    /// `loadRatchets`, a read of the ring it saves (see `BlockedSenderFilter`).
    public static func live(storage: PushStorage,
                            loadRatchets: @escaping @Sendable (_ deliveryHash: Data) -> [Data]? = { _ in nil })
        -> PushServiceHandler {
        let settings = storage.settings.load()
        return PushServiceHandler(
            inbox: storage.inbox,
            settings: settings,
            blockedSenders: storage.blockedSenders.load(),
            loadIdentity: KeychainIdentityLoader.loader(service: settings.keychainService,
                                                        accessGroup: settings.keychainAccessGroup),
            loadRatchets: loadRatchets,
            sendFrames: { host, port, frames in
                await ProofFrameSender.send(host: host, port: port, frames: frames)
            })
    }

    public func handle(userInfo: [AnyHashable: Any]) async -> PushVerdict {
        // Decode before anything crosses an actor boundary: `[AnyHashable: Any]` is not Sendable.
        let packets: [Data]
        do {
            packets = try PushPayload.decode(userInfo)
        } catch {
            return .deliverOriginal
        }
        // A task group would wait for every child, so a non-cooperative wait inside `sendFrames`
        // (NWConnection callbacks) could hold us past the deadline. Race an unstructured task
        // against a timer through a once-resumed continuation instead, then cancel both: the
        // cooperative parts stop, and anything still blocked is abandoned to die with the
        // extension process once the content handler has fired.
        let verdict = LockedVerdict()
        let work = Task { await process(packets, verdict: verdict) }
        let finished = LockedFlag()
        let timerBox = LockIsolatedTask()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task {
                await work.value
                if finished.claim() { continuation.resume() }
            }
            timerBox.task = Task {
                try? await Task.sleep(for: deadline)
                if finished.claim() { continuation.resume() }
            }
        }
        work.cancel()
        timerBox.task?.cancel()
        return verdict.value
    }

    /// `.suppress` iff every decoded packet is attributable and every sender is blocked. Considers every decoded packet, stashed or not: a full disk must not turn a blocked sender's banner back on, and an unattributable packet vetoes (spec A6).
    static func verdict(for packets: [Data], identity: Identity?, ratchets: [Data]? = nil,
                        blockedSenders: Set<String>) -> PushVerdict {
        guard let identity, !blockedSenders.isEmpty else { return .deliverOriginal }
        let deliveryHash = identity.lxmfDeliveryHash
        let senders = packets.compactMap {
            BlockedSenderFilter.sourceHash(of: $0, identity: identity, deliveryHash: deliveryHash,
                                           ratchets: ratchets)
        }
        // Spec A6: an unattributable packet (a LINKREQUEST, a payload encrypted to a ratchet not
        // in `ratchets`) may be someone else's, and the hub batches up to 8 packets per push, so it
        // vetoes suppression.
        guard !senders.isEmpty, senders.count == packets.count else { return .deliverOriginal }
        return senders.allSatisfy { blockedSenders.contains($0.pushHex) } ? .suppress : .deliverOriginal
    }

    private func process(_ packets: [Data], verdict: LockedVerdict) async {
        // A proof promises the message will be delivered. Only promise what is on disk:
        // `append` returning true (written) or false (already there) both count, a throw does not.
        var stashed: [Data] = []
        for raw in packets {
            if (try? inbox.append(raw)) != nil {
                stashed.append(raw)
            }
        }
        // Unconditional on purpose: the verdict must count a packet that could not be stashed
        // (a full disk must not turn a blocked sender's banner back on), so the identity is
        // loaded even when nothing was stashed.
        let identity = loadIdentity()
        // The ring only matters when the verdict could suppress: skip the Keychain read otherwise.
        let ratchets = identity.flatMap { blockedSenders.isEmpty ? nil : loadRatchets($0.lxmfDeliveryHash) }
        verdict.value = Self.verdict(for: packets, identity: identity, ratchets: ratchets,
                                     blockedSenders: blockedSenders)
        guard !stashed.isEmpty, let identity else { return }
        let deliveryHash = identity.lxmfDeliveryHash
        let frames = stashed.compactMap { ProofBuilder.proof(for: $0, identity: identity, deliveryHash: deliveryHash) }
        guard !frames.isEmpty else { return }
        await sendFrames(settings.hubHost, settings.hubPort, frames)
    }
}

/// The verdict behind a lock: written by `process` before its network wait, read by `handle`
/// after the race, whichever side of the deadline `process` is on. Defaults to delivering.
final class LockedVerdict: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: PushVerdict = .deliverOriginal
    var value: PushVerdict {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// A task handle behind a lock, so the timer task started inside a continuation closure can be
/// cancelled afterwards from `handle`.
final class LockIsolatedTask: @unchecked Sendable {
    private let lock = NSLock()
    private var _task: Task<Void, Never>?
    var task: Task<Void, Never>? {
        get { lock.withLock { _task } }
        set { lock.withLock { _task = newValue } }
    }
}
