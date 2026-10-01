import Testing
import Foundation
import Network
import ComposableArchitecture
import ReTiCA
@testable import ReTiCAPushExtension

/// A loopback listener that collects everything one connection writes.
private final class Collector: @unchecked Sendable {
    let listener: NWListener
    let received = LockIsolated(Data())
    let queue = DispatchQueue(label: "collector")

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            read(connection)
        }
        listener.start(queue: queue)
    }

    private func read(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, done, _ in
            if let data { received.withValue { $0.append(data) } }
            if !done { read(connection) }
        }
    }

    var port: Int {
        var p: UInt16 = 0
        for _ in 0..<50 where p == 0 {
            if let actual = listener.port?.rawValue, actual != 0 { p = actual } else { Thread.sleep(forTimeInterval: 0.05) }
        }
        return Int(p)
    }
}

@Test func proofFrameSenderWritesFramesOverLoopback() async throws {
    let collector = try Collector()
    let a = HDLC.frame(Data(repeating: 0xA1, count: 25))
    let b = HDLC.frame(Data(repeating: 0xB2, count: 30))
    await ProofFrameSender.send(host: "127.0.0.1", port: collector.port, frames: [a, b], timeout: .seconds(5))
    for _ in 0..<50 where collector.received.value.count < a.count + b.count {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(collector.received.value == a + b)
    collector.listener.cancel()
}
