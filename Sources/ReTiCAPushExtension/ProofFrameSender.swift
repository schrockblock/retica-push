import Foundation
import Network

/// One short TCP connection to the hub: write every frame, wait for the writes to complete,
/// close. The hub's TCP server interface deframes HDLC and routes the proofs by its reverse
/// table (docs/server-contract.md §2). Errors and timeouts are swallowed: the app proves again
/// on drain, and the sender's retries give several chances.
public enum ProofFrameSender {
    public static func send(host: String, port: Int, frames: [Data], timeout: Duration = .seconds(10)) async {
        guard !frames.isEmpty, let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await write(frames, over: connection) }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
            connection.cancel()
        }
    }

    private static func write(_ frames: [Data], over connection: NWConnection) async {
        let queue = DispatchQueue(label: "ReTiCAPush.ProofFrameSender")
        let ready = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let resumed = LockedFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume(returning: true) }
                case .failed, .cancelled:
                    if resumed.claim() { continuation.resume(returning: false) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
        guard ready else { return }
        for frame in frames {
            let ok = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                connection.send(content: frame, completion: .contentProcessed { error in
                    continuation.resume(returning: error == nil)
                })
            }
            if !ok { return }
        }
    }
}

/// A once-only flag so a continuation resumes exactly once across state callbacks.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
