import Testing
import Foundation
@testable import ReTiCAPushCore

private func freshSuite() -> String { "ReTiCAPushCoreTests.blocked.\(UUID().uuidString)" }

@Test func blockedSenderStoreLoadsEmptyWhenNothingStored() {
    let store = BlockedSenderStore(suiteName: freshSuite())
    #expect(store.load().isEmpty)
}

@Test func blockedSenderStoreRoundTripsASet() {
    let suite = freshSuite()
    let a = String(repeating: "ab", count: 16)
    let b = String(repeating: "cd", count: 16)
    BlockedSenderStore(suiteName: suite).save([a, b])
    #expect(BlockedSenderStore(suiteName: suite).load() == [a, b])
}

@Test func blockedSenderStoreSaveReplacesRatherThanMerges() {
    let suite = freshSuite()
    let a = String(repeating: "ab", count: 16)
    let b = String(repeating: "cd", count: 16)
    let store = BlockedSenderStore(suiteName: suite)
    store.save([a])
    store.save([b])
    #expect(store.load() == [b])
}

@Test func blockedSenderStoreSaveEmptyClears() {
    let suite = freshSuite()
    let store = BlockedSenderStore(suiteName: suite)
    store.save([String(repeating: "ab", count: 16)])
    store.save([])
    #expect(store.load().isEmpty)
}

@Test func blockedSenderStoreLoadsEmptyForAnUndecodableBlob() {
    let suite = freshSuite()
    UserDefaults(suiteName: suite)!.set(Data("not json".utf8), forKey: BlockedSenderStore.key)
    #expect(BlockedSenderStore(suiteName: suite).load().isEmpty)
}

@Test func blockedSenderStoreLowercasesOnLoadAndSave() {
    let suite = freshSuite()
    let upper = String(repeating: "AB", count: 16)
    BlockedSenderStore(suiteName: suite).save([upper])
    #expect(BlockedSenderStore(suiteName: suite).load() == [upper.lowercased()])
    // A blob written by something else, upper-case, loads lower-case too.
    let blob = try! JSONEncoder().encode([String(repeating: "CD", count: 16)])
    UserDefaults(suiteName: suite)!.set(blob, forKey: BlockedSenderStore.key)
    #expect(BlockedSenderStore(suiteName: suite).load() == [String(repeating: "cd", count: 16)])
}

@Test func pushStorageExposesTheBlockedSenderStore() {
    let storage = PushStorage.temporary()
    #expect(storage.blockedSenders.suiteName == storage.settingsSuiteName)
}
