import Foundation
import ReTiCA

/// A directory of raw packets handed over from the service extension to the app (spec §1).
///
/// One file per packet, named `<sequence>-<sha256 hex>`. The sequence is microseconds since the
/// epoch, bumped past any existing entry so two appends in the same microsecond still order by
/// insertion. The hash suffix makes re-appending the same bytes a no-op, so a push whose
/// extension ran and whose tap handler then also stashes it costs nothing.
///
/// Files are written with no file protection on iOS: the extension may run before first unlock,
/// and the bytes are already encrypted to our identity.
public struct PushInbox: Sendable {
    public static let defaultCapacity = 256

    public let directory: URL
    public let capacity: Int

    public init(directory: URL, capacity: Int = PushInbox.defaultCapacity) {
        self.directory = directory
        self.capacity = capacity
    }

    /// Writes `raw` unless an entry with the same bytes exists. Returns whether a file was written.
    /// Evicts the oldest entries so at most `capacity` remain.
    @discardableResult
    public func append(_ raw: Data) throws -> Bool {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hash = Crypto.fullHash(raw).hexString
        let existing = try entryNames()
        guard !existing.contains(where: { $0.hasSuffix("-" + hash) }) else { return false }
        let micros = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        let maxExisting = existing.compactMap(Self.sequence(of:)).max() ?? 0
        let sequence = max(micros, maxExisting + 1)
        let name = String(format: "%020llu-%@", sequence, hash)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.noFileProtection)
        #endif
        try raw.write(to: directory.appending(path: name), options: options)
        let names = try entryNames()
        if names.count > capacity {
            for stale in names.prefix(names.count - capacity) {
                try? FileManager.default.removeItem(at: directory.appending(path: stale))
            }
        }
        return true
    }

    /// Every entry in insertion order, then deletes them all. Empty or unreadable files are
    /// deleted and skipped. A missing directory is an empty inbox.
    public func drain() throws -> [Data] {
        var packets: [Data] = []
        for name in try entryNames() {
            let url = directory.appending(path: name)
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                packets.append(data)
            }
            try? FileManager.default.removeItem(at: url)
        }
        return packets
    }

    public func count() throws -> Int { try entryNames().count }

    /// Entry file names sorted by sequence (the zero-padded prefix sorts lexically).
    private func entryNames() throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path()) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path())
            .filter { $0.contains("-") }
            .sorted()
    }

    private static func sequence(of name: String) -> UInt64? {
        guard let dash = name.firstIndex(of: "-") else { return nil }
        return UInt64(name[name.startIndex..<dash])
    }
}
