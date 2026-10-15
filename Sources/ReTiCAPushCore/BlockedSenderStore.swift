import Foundation

/// The senders the host app has blocked, mirrored into the app-group defaults so the service
/// extension can suppress their banners (spec 2026-10-15 §4). One JSON array of lowercase
/// 32-character hex `lxmf.delivery` hashes under `key`, next to `SharedPushSettingsStore.key`
/// in the same suite. The app writes it on every change and on launch; the extension reads it
/// once per push. `SharedPushSettings` is untouched, so an older extension build ignores this.
public struct BlockedSenderStore: Sendable {
    public static let key = "retica.push.blockedSenders"

    /// The app-group suite. nil means `UserDefaults.standard` (never what the extension reads).
    public let suiteName: String?

    public init(suiteName: String?) { self.suiteName = suiteName }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    /// Empty when nothing is stored or the blob does not decode. Entries are lowercased so a
    /// list written with upper-case hex still matches `Data.hexString`.
    public func load() -> Set<String> {
        guard let data = defaults.data(forKey: Self.key),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(list.map { $0.lowercased() })
    }

    /// Replaces the stored list. Lowercases on the way in for the same reason as `load`.
    public func save(_ senders: Set<String>) {
        let list = senders.map { $0.lowercased() }.sorted()
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
