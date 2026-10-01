import Foundation
import ReTiCA
import ReTiCAPushCore

/// What the Notification Service Extension does with a push (spec §1): stash every packet in the
/// shared inbox, sign a proof for each DATA packet addressed to our delivery hash, write the
/// proofs to the hub over one short connection. Nothing is decrypted and the notification is
/// never changed, so the extension always hands back the original content afterwards.
///
/// `handle` itself always returns by `deadline`: `process` runs unstructured and is raced against
/// a timer, so a non-cooperative wait inside `sendFrames` (e.g. an `NWConnection` callback) cannot
/// hold the call past the deadline — it is simply abandoned, to die with the extension process once
/// the content handler has fired. A locked Keychain (before first unlock) means the packets are
/// stashed and nothing is proved.
public struct PushServiceHandler: Sendable {
    public let inbox: PushInbox
    public let settings: SharedPushSettings
    public let loadIdentity: @Sendable () -> Identity?
    public let sendFrames: @Sendable (_ host: String, _ port: Int, _ frames: [Data]) async -> Void
    public let deadline: Duration

    public init(inbox: PushInbox, settings: SharedPushSettings,
                loadIdentity: @escaping @Sendable () -> Identity?,
                sendFrames: @escaping @Sendable (_ host: String, _ port: Int, _ frames: [Data]) async -> Void,
                deadline: Duration = .seconds(20)) {
        self.inbox = inbox
        self.settings = settings
        self.loadIdentity = loadIdentity
        self.sendFrames = sendFrames
        self.deadline = deadline
    }

    /// The real thing: inbox and settings from `storage`, identity from the shared Keychain,
    /// proofs over `ProofFrameSender`.
    public static func live(storage: PushStorage) -> PushServiceHandler {
        let settings = storage.settings.load()
        return PushServiceHandler(
            inbox: storage.inbox,
            settings: settings,
            loadIdentity: KeychainIdentityLoader.loader(service: settings.keychainService,
                                                        accessGroup: settings.keychainAccessGroup),
            sendFrames: { host, port, frames in
                await ProofFrameSender.send(host: host, port: port, frames: frames)
            })
    }

    public func handle(userInfo: [AnyHashable: Any]) async {
        // Decode before anything crosses an actor boundary: `[AnyHashable: Any]` is not Sendable.
        let packets: [Data]
        do {
            packets = try PushPayload.decode(userInfo)
        } catch {
            return
        }
        // A task group would wait for every child, so a non-cooperative wait inside `sendFrames`
        // (NWConnection callbacks) could hold us past the deadline. Race an unstructured task
        // against a timer through a once-resumed continuation instead, then cancel both: the
        // cooperative parts stop, and anything still blocked is abandoned to die with the
        // extension process once the content handler has fired.
        let work = Task { await process(packets) }
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
    }

    private func process(_ packets: [Data]) async {
        // A proof promises the message will be delivered. Only promise what is on disk:
        // `append` returning true (written) or false (already there) both count, a throw does not.
        var stashed: [Data] = []
        for raw in packets {
            if (try? inbox.append(raw)) != nil {
                stashed.append(raw)
            }
        }
        guard !stashed.isEmpty, let identity = loadIdentity() else { return }
        let deliveryHash = identity.lxmfDeliveryHash
        let frames = stashed.compactMap { ProofBuilder.proof(for: $0, identity: identity, deliveryHash: deliveryHash) }
        guard !frames.isEmpty else { return }
        await sendFrames(settings.hubHost, settings.hubPort, frames)
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
