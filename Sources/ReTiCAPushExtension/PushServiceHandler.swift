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

/// The one verified sender a push names: the directory entry the host app wrote for them, and the
/// picture file's location when the entry has one.
public struct PushSenderMatch: Equatable, Sendable {
    /// Lowercase hex lxmf.delivery hash, the directory key.
    public var hex: String
    public var entry: SenderDirectory.Entry
    public var imageURL: URL?

    public init(hex: String, entry: SenderDirectory.Entry, imageURL: URL?) {
        self.hex = hex
        self.entry = entry
        self.imageURL = imageURL
    }
}

/// What `outcome` returns: the verdict, and the sender to show on the banner when exactly one
/// verified, known sender wrote every packet. `.suppress` wins over any sender.
public struct PushOutcome: Equatable, Sendable {
    public var verdict: PushVerdict
    public var sender: PushSenderMatch?

    public init(verdict: PushVerdict, sender: PushSenderMatch? = nil) {
        self.verdict = verdict
        self.sender = sender
    }
}

/// What the Notification Service Extension does with a push (push spec §1, block spec §4):
/// stash every packet in the shared inbox, decide whether the banner should show, sign a proof
/// for each DATA packet addressed to our delivery hash, write the proofs to the hub over one
/// short connection. The only decryption is `BlockedSenderFilter`'s read of the sender hash,
/// for the verdict, and the verified read of the sender for display: a packet is attributed to a
/// sender only when its LXMF signature verifies against the public key the host app stored in the
/// sender directory. The content is never read and nothing leaves this type but the outcome.
///
/// `handle` itself always returns by `deadline`: `process` runs unstructured and is raced against
/// a timer, so a non-cooperative wait inside `sendFrames` (e.g. an `NWConnection` callback) cannot
/// hold the call past the deadline — it is simply abandoned, to die with the extension process once
/// the content handler has fired. The verdict and the sender are decided before that wait and parked
/// in a locked box, so a late sender never costs either. A locked Keychain (before first unlock) means the
/// packets are stashed, nothing is proved and the original is delivered.
public struct PushServiceHandler: Sendable {
    public let inbox: PushInbox
    public let settings: SharedPushSettings
    /// Lowercase hex lxmf.delivery hashes from `BlockedSenderStore`.
    public let blockedSenders: Set<String>
    /// Who the host knows, for naming the sender on the banner.
    public let senders: SenderDirectory
    /// Resolves a directory entry's picture file; nil leaves `PushSenderMatch.imageURL` nil.
    public let sendersStore: SenderDirectoryStore?
    public let loadIdentity: @Sendable () -> Identity?
    /// The host's own ratchet ring (X25519 private keys, newest first) for a delivery hash, or nil
    /// when it has none or cannot read it. READ-ONLY: the extension never saves or rotates a ring;
    /// only the app does. Used to attribute packets, for the verdict and for the sender's name, when
    /// the blocklist or the sender directory is non-empty.
    public let loadRatchets: @Sendable (_ deliveryHash: Data) -> [Data]?
    public let sendFrames: @Sendable (_ host: String, _ port: Int, _ frames: [Data]) async -> Void
    public let deadline: Duration

    public init(inbox: PushInbox, settings: SharedPushSettings,
                blockedSenders: Set<String> = [],
                senders: SenderDirectory = .empty,
                sendersStore: SenderDirectoryStore? = nil,
                loadIdentity: @escaping @Sendable () -> Identity?,
                loadRatchets: @escaping @Sendable (_ deliveryHash: Data) -> [Data]? = { _ in nil },
                sendFrames: @escaping @Sendable (_ host: String, _ port: Int, _ frames: [Data]) async -> Void,
                deadline: Duration = .seconds(20)) {
        self.inbox = inbox
        self.settings = settings
        self.blockedSenders = Set(blockedSenders.map { $0.lowercased() })
        self.senders = senders
        self.sendersStore = sendersStore
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
            senders: storage.senderDirectory.load(),
            sendersStore: storage.senderDirectory,
            loadIdentity: KeychainIdentityLoader.loader(service: settings.keychainService,
                                                        accessGroup: settings.keychainAccessGroup),
            loadRatchets: loadRatchets,
            sendFrames: { host, port, frames in
                await ProofFrameSender.send(host: host, port: port, frames: frames)
            })
    }

    public func handle(userInfo: [AnyHashable: Any]) async -> PushVerdict {
        await outcome(userInfo: userInfo).verdict
    }

    public func outcome(userInfo: [AnyHashable: Any]) async -> PushOutcome {
        // Decode before anything crosses an actor boundary: `[AnyHashable: Any]` is not Sendable.
        let packets: [Data]
        do {
            packets = try PushPayload.decode(userInfo)
        } catch {
            return PushOutcome(verdict: .deliverOriginal)
        }
        // A task group would wait for every child, so a non-cooperative wait inside `sendFrames`
        // (NWConnection callbacks) could hold us past the deadline. Race an unstructured task
        // against a timer through a once-resumed continuation instead, then cancel both: the
        // cooperative parts stop, and anything still blocked is abandoned to die with the
        // extension process once the content handler has fired.
        let outcome = LockedOutcome()
        let work = Task { await process(packets, outcome: outcome) }
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
        return outcome.value
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

    /// The hex of the one sender who wrote every packet, verified against the public key in
    /// `senders`; nil when any packet fails to verify, the senders differ, or there is no identity.
    static func sender(for packets: [Data], identity: Identity?, ratchets: [Data]? = nil,
                       senders: SenderDirectory) -> String? {
        guard let identity, !packets.isEmpty else { return nil }
        let deliveryHash = identity.lxmfDeliveryHash
        let verified = packets.compactMap {
            PushSender.verifiedSource(of: $0, identity: identity, deliveryHash: deliveryHash,
                                      ratchets: ratchets,
                                      publicKeyFor: { senders.entries[$0.pushHex]?.publicKey })
        }
        guard verified.count == packets.count, let first = verified.first,
              verified.allSatisfy({ $0 == first }) else { return nil }
        return first.pushHex
    }

    private func process(_ packets: [Data], outcome: LockedOutcome) async {
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
        // The ring only matters when something could be attributed, for the verdict or for the
        // sender's name: skip the Keychain read otherwise. Loaded once, used for both.
        let ratchets = identity.flatMap {
            blockedSenders.isEmpty && senders.entries.isEmpty ? nil : loadRatchets($0.lxmfDeliveryHash)
        }
        let verdict = Self.verdict(for: packets, identity: identity, ratchets: ratchets,
                                   blockedSenders: blockedSenders)
        let match = Self.sender(for: packets, identity: identity, ratchets: ratchets, senders: senders)
            .flatMap { hex in
                senders.entries[hex].map {
                    PushSenderMatch(hex: hex, entry: $0, imageURL: sendersStore?.imageURL(for: $0))
                }
            }
        outcome.value = PushOutcome(verdict: verdict, sender: match)
        guard !stashed.isEmpty, let identity else { return }
        let deliveryHash = identity.lxmfDeliveryHash
        let frames = stashed.compactMap { ProofBuilder.proof(for: $0, identity: identity, deliveryHash: deliveryHash) }
        guard !frames.isEmpty else { return }
        await sendFrames(settings.hubHost, settings.hubPort, frames)
    }
}

/// The outcome behind a lock: written by `process` before its network wait, read by `outcome`
/// after the race, whichever side of the deadline `process` is on. Defaults to delivering, no sender.
final class LockedOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = PushOutcome(verdict: .deliverOriginal)
    var value: PushOutcome {
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
