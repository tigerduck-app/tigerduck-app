import Defaults
import Foundation
import Security

/// The device's UUIDv4 and the secret that proves it to the backend's anonymous registration,
/// kept together in the Keychain so both survive a reinstall and neither leaves the device.
nonisolated struct PushIdentity: Sendable {
    let uuid: String
    /// Sent as `device_secret`; nil when a newly minted one could not be saved.
    let secret: String?
    /// False when the Keychain could not be read at launch.
    let mayAnnounce: Bool

    init(uuid: String, secret: String? = nil, mayAnnounce: Bool = true) {
        self.uuid = uuid
        self.secret = secret
        self.mayAnnounce = mayAnnounce
    }

    nonisolated struct Store: Sendable {
        /// Throws when the item cannot be read now rather than being absent.
        let read: @Sendable (_ key: String) throws -> String?
        let save: @Sendable (_ key: String, _ value: String) -> Bool
        let delete: @Sendable (_ key: String) -> Void

        static let keychain = Store(
            // Bare Keychain items need `loadString`; `loadIfReadable` does not read them.
            read: { try KeychainManager.loadString(key: $0) ?? KeychainManager.loadStringIfReadable(key: $0) },
            save: { KeychainManager.saveStringReportingSuccess(key: $0, value: $1) },
            delete: { KeychainManager.delete(key: $0) }
        )
    }

    private static let idKey = AppConstants.KeychainKeys.pushDeviceId
    private static let secretKey = AppConstants.KeychainKeys.pushDeviceSecret
    private static let legacyIdKey = "push_user_id"

    static func loadOrCreate(from store: Store = .keychain) -> PushIdentity {
        var id: String?
        do {
            id = try store.read(idKey).flatMap { $0.isEmpty ? nil : $0 } ?? movedLegacyId(in: store)
            if let id, let secret = try store.read(secretKey), !secret.isEmpty {
                return PushIdentity(uuid: id, secret: secret)
            }
        } catch {
            return PushIdentity(uuid: id ?? UUID().uuidString.lowercased(), mayAnnounce: false)
        }
        let uuid = id ?? mintedId(in: store)
        let secret = mintSecret().flatMap { store.save(secretKey, $0) ? $0 : nil }
        return PushIdentity(uuid: uuid, secret: secret)
    }

    /// After the backend refused the secret, a launch with no backend session stored discards the
    /// id and secret, so `loadOrCreate` mints new ones. The backend keys a signed-in device and its
    /// Live Activity rows by the id, and a sign-out's kept session deletes that device by it.
    static func startOverIfRefused(in store: Store = .keychain) {
        guard Defaults[.pushDeviceSecretRefused], storesNoSession(in: store) else { return }
        store.delete(idKey)
        store.delete(secretKey)
        Defaults[.pushDeviceSecretRefused] = false
    }

    /// Whether the Keychain, read now, holds neither a backend session nor one a sign-out keeps.
    static func storesNoSession(in store: Store) -> Bool {
        let sessionKeys = [AuthTokenManager.refreshTokenKey, AuthTokenManager.departingSessionKey]
        guard case .success(let sessions) = Result(catching: { try sessionKeys.compactMap(store.read) }) else {
            return false
        }
        return sessions.isEmpty
    }

    /// 32 random bytes as unpadded base64url, the 43 characters the backend accepts.
    static func mintSecret() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func mintedId(in store: Store) -> String {
        let minted = UUID().uuidString.lowercased()
        _ = store.save(idKey, minted)
        return minted
    }

    private static func movedLegacyId(in store: Store) -> String? {
        guard let legacy = try? store.read(legacyIdKey), !legacy.isEmpty else { return nil }
        _ = store.save(idKey, legacy)
        store.delete(legacyIdKey)
        return legacy
    }
}
