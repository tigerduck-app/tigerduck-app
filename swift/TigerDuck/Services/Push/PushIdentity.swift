import Foundation

nonisolated struct PushIdentity: Sendable {
    let uuid: String

    static func loadOrCreate() -> PushIdentity {
        if let existing = KeychainManager.loadString(
            key: AppConstants.KeychainKeys.pushDeviceId
        ), !existing.isEmpty {
            return PushIdentity(uuid: existing)
        }
        if let legacy = KeychainManager.loadString(
            key: "push_user_id"
        ), !legacy.isEmpty {
            KeychainManager.saveString(
                key: AppConstants.KeychainKeys.pushDeviceId,
                value: legacy
            )
            KeychainManager.delete(key: "push_user_id")
            return PushIdentity(uuid: legacy)
        }
        let minted = UUID().uuidString.lowercased()
        KeychainManager.saveString(
            key: AppConstants.KeychainKeys.pushDeviceId,
            value: minted
        )
        return PushIdentity(uuid: minted)
    }
}
