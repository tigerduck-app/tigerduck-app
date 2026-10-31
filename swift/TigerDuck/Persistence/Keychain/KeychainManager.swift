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

    static func deleteReportingSuccess(key: String) -> Bool {
        SecureStore.deleteReportingSuccess(key: key)
    }

    static func loadString(key: String) -> String? {
        guard let data = load(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func loadStringIfReadable(key: String) throws -> String? {
        try SecureStore.loadIfReadable(key: key).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func saveString(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        save(key: key, data: data)
    }

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
