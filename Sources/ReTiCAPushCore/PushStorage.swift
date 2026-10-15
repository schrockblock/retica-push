import Foundation

/// Where the inbox and the shared settings live. Both processes build it from the same app
/// group, so they cannot disagree (spec resolution in the plan).
public struct PushStorage: Equatable, Sendable {
    public var inboxDirectory: URL
    public var settingsSuiteName: String?

    public init(inboxDirectory: URL, settingsSuiteName: String?) {
        self.inboxDirectory = inboxDirectory
        self.settingsSuiteName = settingsSuiteName
    }

    /// `<container>/ReTiCAPush/inbox` and the app group id as the defaults suite.
    public init(containerURL: URL, appGroupID: String) {
        self.init(inboxDirectory: containerURL.appending(path: "ReTiCAPush/inbox", directoryHint: .isDirectory),
                  settingsSuiteName: appGroupID)
    }

    /// nil when the process has no container for `id` (missing entitlement).
    public static func appGroup(_ id: String) -> PushStorage? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
        else { return nil }
        return PushStorage(containerURL: container, appGroupID: id)
    }

    /// A throwaway location for tests and previews.
    public static func temporary() -> PushStorage {
        let suite = "ReTiCAPush.temporary.\(UUID().uuidString)"
        return PushStorage(
            inboxDirectory: FileManager.default.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory),
            settingsSuiteName: suite)
    }

    public var inbox: PushInbox { PushInbox(directory: inboxDirectory) }
    public var settings: SharedPushSettingsStore { SharedPushSettingsStore(suiteName: settingsSuiteName) }
    public var blockedSenders: BlockedSenderStore { BlockedSenderStore(suiteName: settingsSuiteName) }
}
