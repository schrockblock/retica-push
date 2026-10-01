import Testing
import Foundation
@testable import ReTiCAPushCore

private func freshDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "ReTiCAPushTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private func packet(_ n: UInt8) -> Data { Data([0x00, 0x00, n, n &+ 1, n &+ 2]) }

@Test func pushInboxAppendThenDrainReturnsInOrderAndEmpties() throws {
    let inbox = PushInbox(directory: freshDirectory())
    try inbox.append(packet(1))
    try inbox.append(packet(2))
    try inbox.append(packet(3))
    #expect(try inbox.drain() == [packet(1), packet(2), packet(3)])
    #expect(try inbox.drain() == [])
}

@Test func pushInboxReappendOfSameBytesIsANoOp() throws {
    let inbox = PushInbox(directory: freshDirectory())
    #expect(try inbox.append(packet(7)) == true)
    #expect(try inbox.append(packet(7)) == false)
    #expect(try inbox.count() == 1)
}

@Test func pushInboxEvictsOldestBeyondCapacity() throws {
    let inbox = PushInbox(directory: freshDirectory(), capacity: 3)
    for n: UInt8 in 1...4 { try inbox.append(packet(n)) }
    #expect(try inbox.drain() == [packet(2), packet(3), packet(4)])
}

@Test func pushInboxDrainOnMissingDirectoryReturnsEmpty() throws {
    let inbox = PushInbox(directory: freshDirectory())
    #expect(try inbox.drain() == [])
    #expect(try inbox.count() == 0)
}

@Test func pushInboxOrdersByInsertionNotByHash() throws {
    // Eight packets: the chance their hashes happen to sort in insertion order is 1 in 40320.
    let inbox = PushInbox(directory: freshDirectory())
    let packets = (10...17).map { packet(UInt8($0)) }
    for p in packets { try inbox.append(p) }
    #expect(try inbox.drain() == packets)
}

@Test func pushInboxDrainSkipsAnUnreadableEntry() throws {
    let directory = freshDirectory()
    let inbox = PushInbox(directory: directory)
    try inbox.append(packet(1))
    // A stray empty file in the inbox directory, as a killed extension could leave behind.
    try Data().write(to: directory.appending(path: "0000000000000000-deadbeef"))
    try inbox.append(packet(2))
    #expect(try inbox.drain() == [packet(1), packet(2)])
    #expect(try inbox.count() == 0)
}
