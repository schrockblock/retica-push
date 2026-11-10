import Foundation

/// Where the inbox and the shared settings live. Both processes build it from the same app
/// group, so they cannot disagree (spec resolution in the plan).
public struct PushStorage: Equatable, Sendable {
    public var inboxDirectory: URL
    public var settingsSuiteName: String?
    public var sendersDirectory: URL

    public init(inboxDirectory: URL, settingsSuiteName: String?, sendersDirectory: URL? = nil) {
        self.inboxDirectory = inboxDirectory
        self.settingsSuiteName = settingsSuiteName
        self.sendersDirectory = sendersDirectory
            ?? inboxDirectory.deletingLastPathComponent().appending(path: "senders", directoryHint: .isDirectory)
    }

    /// `<container>/ReTiCAPush/inbox`, `<container>/ReTiCAPush/senders` and the app group id as the defaults suite.
    public init(containerURL: URL, appGroupID: String) {
        self.init(inboxDirectory: containerURL.appending(path: "ReTiCAPush/inbox", directoryHint: .isDirectory),
                  settingsSuiteName: appGroupID,
                  sendersDirectory: containerURL.appending(path: "ReTiCAPush/senders", directoryHint: .isDirectory))
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
        let root = FileManager.default.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory)
        return PushStorage(
            inboxDirectory: root.appending(path: "inbox", directoryHint: .isDirectory),
            settingsSuiteName: suite,
            sendersDirectory: root.appending(path: "senders", directoryHint: .isDirectory))
    }

    public var inbox: PushInbox { PushInbox(directory: inboxDirectory) }
    public var settings: SharedPushSettingsStore { SharedPushSettingsStore(suiteName: settingsSuiteName) }
    public var blockedSenders: BlockedSenderStore { BlockedSenderStore(suiteName: settingsSuiteName) }
    public var senderDirectory: SenderDirectoryStore { SenderDirectoryStore(directory: sendersDirectory) }
}
