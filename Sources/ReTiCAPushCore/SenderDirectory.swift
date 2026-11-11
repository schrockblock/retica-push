import Foundation
import CryptoKit

/// Who each sender is, as the host app last wrote it: name, public key and an optional picture,
/// keyed by the sender's lowercase hex destination hash. The extension reads it once per push.
public struct SenderDirectory: Equatable, Sendable {
    public static let version = 1
    public static let empty = SenderDirectory(entries: [:])

    public var entries: [String: Entry]

    public init(entries: [String: Entry]) {
        self.entries = entries
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var name: String?
        public var publicKey: Data
        /// File name beside `directory.json`; resolve it with `SenderDirectoryStore.imageURL(for:)`.
        public var imageFile: String?
        /// The `CNContact.identifier` the sender is linked to, so iOS can match the banner's sender
        /// to that card. Absent from files written before it existed, which still decode.
        public var contactIdentifier: String?

        public init(name: String?, publicKey: Data, imageFile: String?, contactIdentifier: String? = nil) {
            self.name = name
            self.publicKey = publicKey
            self.imageFile = imageFile
            self.contactIdentifier = contactIdentifier
        }
    }

    /// What the app hands to `SenderDirectoryStore.save`.
    public struct Input: Equatable, Sendable {
        public var name: String?
        public var publicKey: Data
        public var imageData: Data?
        public var contactIdentifier: String?

        public init(name: String?, publicKey: Data, imageData: Data?, contactIdentifier: String? = nil) {
            self.name = name
            self.publicKey = publicKey
            self.imageData = imageData
            self.contactIdentifier = contactIdentifier
        }
    }
}

/// Reads and writes the sender directory in a folder both processes can reach.
///
/// `directory.json` is replaced atomically, so a reader that lands mid-rewrite sees the old or the
/// new file, never a torn one. Images are content-addressed (`<sha256>.jpg`), so a rewrite never
/// changes a file a reader may be opening. The orphan sweep can still delete an image that a
/// reader of the old JSON has not opened yet; that is safe, because the read fails and no avatar
/// shows.
public struct SenderDirectoryStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private struct Envelope: Codable {
        var v: Int
        var entries: [String: SenderDirectory.Entry]
    }

    private var jsonURL: URL { directory.appending(path: "directory.json") }

    public func save(_ inputs: [String: SenderDirectory.Input]) throws {
        try ensureDirectory()
        let fm = FileManager.default

        var entries: [String: SenderDirectory.Entry] = [:]
        for (key, input) in inputs {
            var imageFile: String?
            if let imageData = input.imageData {
                let name = SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined() + ".jpg"
                let url = directory.appending(path: name)
                if !fm.fileExists(atPath: url.path) {
                    try imageData.write(to: url, options: writeOptions)
                }
                imageFile = name
            }
            entries[key.lowercased()] = .init(name: input.name, publicKey: input.publicKey, imageFile: imageFile,
                                              contactIdentifier: input.contactIdentifier)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(Envelope(v: SenderDirectory.version, entries: entries))
        let temp = directory.appending(path: "directory.json.\(UUID().uuidString).tmp")
        try json.write(to: temp, options: writeOptions)
        do {
            if fm.fileExists(atPath: jsonURL.path) {
                _ = try fm.replaceItemAt(jsonURL, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: jsonURL)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }

        let referenced = Set(entries.values.compactMap(\.imageFile))
        for file in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        where file.hasSuffix(".jpg") && !referenced.contains(file) {
            try? fm.removeItem(at: directory.appending(path: file))
        }
    }

    /// `.empty` when the file is missing, unreadable, malformed or of another version.
    public func load() -> SenderDirectory {
        guard let data = try? Data(contentsOf: jsonURL),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.v == SenderDirectory.version
        else { return .empty }
        var entries: [String: SenderDirectory.Entry] = [:]
        for (key, entry) in envelope.entries { entries[key.lowercased()] = entry }
        return SenderDirectory(entries: entries)
    }

    /// The picture file for `entry`, nil when it has none or the stored name is not a plain file
    /// name ending in `.jpg` (so a damaged file can't point outside the folder or at `directory.json`).
    public func imageURL(for entry: SenderDirectory.Entry) -> URL? {
        guard let file = entry.imageFile,
              file.hasSuffix(".jpg"), file != ".jpg",
              !file.contains("/"), !file.contains("\0"),
              file != ".", file != ".."
        else { return nil }
        return directory.appending(path: file)
    }

    private var writeOptions: Data.WritingOptions {
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        return options
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = directory
        try dir.setResourceValues(values)
    }
}
