import Foundation
import ReTiCA
import ReTiCAKeychain

/// Loads the shared identity the app stores (the same `IdentityKeychain.Location` the app uses,
/// read from `SharedPushSettings`). Never mints: `loadOrCreate` would rotate the identity if the
/// item is unreadable. nil for absent, locked (before first unlock) or any failure.
public enum KeychainIdentityLoader {
    public static func loader(service: String, accessGroup: String?,
                              ops: KeychainOps = .live) -> @Sendable () -> Identity? {
        let location = IdentityKeychain.Location(service: service, accessGroup: accessGroup)
        return { IdentityKeychain.load(shared: location, legacy: [], ops: ops).identity }
    }
}
