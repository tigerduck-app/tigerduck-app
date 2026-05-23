import Foundation

nonisolated enum KeychainManager {
    static func save(key: String, data: Data) {
        try? SecureStore.save(data, forKey: key)
    }

    static func load(key: String) -> Data? {
        SecureStore.load(key: key)
    }

    static func delete(key: String) {
        SecureStore.delete(key: key)
    }

    /// Returns true when the item is gone after the call (deleted now or
    /// already absent). The fresh-install cleanup in `AppState.init` uses
    /// this so a partial failure doesn't flip `appHasBeenInstalled` and
    /// permanently strand the cleanup.
    static func deleteReportingSuccess(key: String) -> Bool {
        SecureStore.deleteReportingSuccess(key: key)
    }

    static func loadString(key: String) -> String? {
        guard let data = load(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveString(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        save(key: key, data: data)
    }

    /// Like ``saveString(key:value:)`` but surfaces the Keychain write
    /// status to the caller. Returns true only when the new value is
    /// confirmed written; false on any encoding or Keychain error.
    /// Use when a silent persistence failure would mislead the user —
    /// e.g. the Debug endpoint override, which must not pretend to have
    /// saved a URL it never actually stored.
    static func saveStringReportingSuccess(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        do {
            try SecureStore.save(data, forKey: key)
            return true
        } catch {
            return false
        }
    }
}
