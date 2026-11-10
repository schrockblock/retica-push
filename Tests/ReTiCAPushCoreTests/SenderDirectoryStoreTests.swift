import Testing
import Foundation
@testable import ReTiCAPushCore

private func store() -> SenderDirectoryStore {
    SenderDirectoryStore(directory: FileManager.default.temporaryDirectory
        .appending(path: "SenderDirectory-\(UUID().uuidString)", directoryHint: .isDirectory))
}
private let keyA = Data(repeating: 0xA1, count: 64), keyB = Data(repeating: 0xB2, count: 64)
private let hexA = String(repeating: "a", count: 32), hexB = String(repeating: "b", count: 32)

@Test func senderDirectoryRoundTripsNamesKeysAndImages() throws {
    let s = store()
    try s.save([hexA: .init(name: "Alice", publicKey: keyA, imageData: Data([1, 2, 3])),
                hexB: .init(name: nil, publicKey: keyB, imageData: nil)])
    let dir = s.load()
    #expect(dir.entries[hexA]?.name == "Alice")
    #expect(dir.entries[hexA]?.publicKey == keyA)
    let entryA = try #require(dir.entries[hexA])
    let imageURL = try #require(s.imageURL(for: entryA))
    #expect(try Data(contentsOf: imageURL) == Data([1, 2, 3]))
    #expect(dir.entries[hexB]?.imageFile == nil)
}

@Test func senderDirectoryLowercasesKeys() throws {
    let s = store()
    try s.save([hexA.uppercased(): .init(name: "Alice", publicKey: keyA, imageData: nil)])
    #expect(s.load().entries[hexA]?.name == "Alice")
}

@Test func senderDirectoryRemovesImagesNoEntryNames() throws {
    let s = store()
    try s.save([hexA: .init(name: "A", publicKey: keyA, imageData: Data([1]))])
    try s.save([hexA: .init(name: "A", publicKey: keyA, imageData: Data([2]))])
    let jpgs = try FileManager.default.contentsOfDirectory(atPath: s.directory.path).filter { $0.hasSuffix(".jpg") }
    #expect(jpgs.count == 1)
}

@Test func senderDirectoryKeepsAStillReferencedImageOnReSave() throws {
    let s = store()
    try s.save([hexA: .init(name: "A", publicKey: keyA, imageData: Data([1])),
                hexB: .init(name: "B", publicKey: keyB, imageData: Data([2]))])
    let before = s.load()
    let entryA = try #require(before.entries[hexA])
    let entryB = try #require(before.entries[hexB])
    let urlA = try #require(s.imageURL(for: entryA))
    let urlB = try #require(s.imageURL(for: entryB))
    try s.save([hexA: .init(name: "A", publicKey: keyA, imageData: Data([1]))])
    #expect(try Data(contentsOf: urlA) == Data([1]))
    #expect(!FileManager.default.fileExists(atPath: urlB.path))
}

@Test func senderDirectoryImageURLRejectsAnythingButAPlainJpgName() {
    let s = store()
    func url(_ file: String?) -> URL? {
        s.imageURL(for: .init(name: nil, publicKey: keyA, imageFile: file))
    }
    #expect(url("abc.jpg") == s.directory.appending(path: "abc.jpg"))
    #expect(url(nil) == nil)
    for bad in ["", ".", "..", "directory.json", "../abc.jpg", "a/b.jpg", "/etc/abc.jpg", "abc.png"] {
        #expect(url(bad) == nil, "\(bad)")
    }
}

@Test func senderDirectoryIsEmptyWhenMissing() {
    #expect(store().load() == .empty)
}

@Test func senderDirectoryIgnoresATruncatedFile() throws {
    let s = store()
    try s.save([hexA: .init(name: "A", publicKey: keyA, imageData: nil)])
    let json = s.directory.appending(path: "directory.json")
    let bytes = try Data(contentsOf: json)
    try bytes.prefix(bytes.count / 2).write(to: json)
    #expect(s.load() == .empty)
}

@Test func senderDirectoryIgnoresAnUnknownVersion() throws {
    let s = store()
    try s.save([hexA: .init(name: "A", publicKey: keyA, imageData: nil)])
    let json = s.directory.appending(path: "directory.json")
    let text = try String(contentsOf: json, encoding: .utf8).replacingOccurrences(of: "\"v\":1", with: "\"v\":2")
    try Data(text.utf8).write(to: json)
    #expect(s.load() == .empty)
}

@Test func pushStorageSendersDirectoryIsBesideTheInbox() {
    let container = URL(filePath: "/tmp/container", directoryHint: .isDirectory)
    let storage = PushStorage(containerURL: container, appGroupID: "group.x")
    #expect(storage.sendersDirectory.path().hasSuffix("ReTiCAPush/senders/"))
    #expect(PushStorage.temporary().sendersDirectory != PushStorage.temporary().sendersDirectory)
}
