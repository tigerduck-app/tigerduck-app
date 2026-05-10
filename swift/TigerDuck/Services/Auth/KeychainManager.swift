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
}
