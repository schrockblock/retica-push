import Testing
import Foundation
@testable import ReTiCAPushCore

private func freshSuite() -> String {
    let suite = "ReTiCAPushTests.\(UUID().uuidString)"
    UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
    return suite
}

@Test func sharedPushSettingsRoundTripThroughDefaults() {
    let store = SharedPushSettingsStore(suiteName: freshSuite())
    let settings = SharedPushSettings(
        hubHost: "hub.example.net", hubPort: 4242,
        keychainService: "reticulum.identity", keychainAccessGroup: "TEAM.co.example.identity",
        lastRegistration: RegistrationRecord(tokenHex: "aabb", registeredAt: Date(timeIntervalSince1970: 1_700_000_000)))
    store.save(settings)
    #expect(store.load() == settings)
}

@Test func sharedPushSettingsLoadReturnsDefaultsWhenAbsent() {
    let store = SharedPushSettingsStore(suiteName: freshSuite())
    #expect(store.load() == SharedPushSettings())
}

@Test func sharedPushSettingsLoadReturnsDefaultsWhenCorrupt() {
    let suite = freshSuite()
    UserDefaults(suiteName: suite)!.set(Data("not json".utf8), forKey: SharedPushSettingsStore.key)
    #expect(SharedPushSettingsStore(suiteName: suite).load() == SharedPushSettings())
}

@Test func pushStorageAppGroupDerivesInboxAndSuite() {
    let storage = PushStorage(containerURL: URL(filePath: "/containers/group"), appGroupID: "group.co.example.app")
    #expect(storage.inboxDirectory.path() == "/containers/group/ReTiCAPush/inbox/")
    #expect(storage.settingsSuiteName == "group.co.example.app")
}
