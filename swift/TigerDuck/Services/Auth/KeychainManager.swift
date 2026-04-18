import Foundation

enum KeychainManager {
    static func save(key: String, data: Data) {
        try? SecureStore.save(data, forKey: key)
    }

    static func load(key: String) -> Data? {
        SecureStore.load(key: key)
    }

    static func delete(key: String) {
        SecureStore.delete(key: key)
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
