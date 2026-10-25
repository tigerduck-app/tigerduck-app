import Foundation

/// The departing-session key held one session as a JSON object; it holds a list now, one per
/// backend, and an object an earlier version kept becomes the list's only entry.
enum DepartingSessionListMigration {
    private static let doneKey = "DepartingSessionListMigration.v1.done"

    static func runIfNeeded(
        defaults: UserDefaults = .standard,
        read: () throws -> String? = { try KeychainManager.loadStringIfReadable(key: AuthTokenManager.departingSessionKey) },
        write: (String) -> Bool = {
            KeychainManager.saveStringReportingSuccess(key: AuthTokenManager.departingSessionKey, value: $0)
        }
    ) {
        guard !defaults.bool(forKey: doneKey) else { return }
        let stored: String?
        do { stored = try read() } catch { return }
        if let stored, stored.hasPrefix("{") {
            guard write("[" + stored + "]") else { return }
        }
        defaults.set(true, forKey: doneKey)
    }
}
