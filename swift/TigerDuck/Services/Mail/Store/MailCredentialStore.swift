#if os(iOS)
import Foundation
import Valet

nonisolated protocol MailSecretStorage: Sendable {
    func save(_ value: String, forKey key: String) throws
    func load(forKey key: String) -> String?
    func delete(forKey key: String)
    func deleteAll()
}

/// The School Mail password's Keychain home — the one deliberate exception to
/// `SecureStore`'s `.whenUnlockedThisDeviceOnly` (design doc §7.2). New-mail checks run
/// from Background App Refresh, usually while the phone is locked, so this Valet uses
/// `.afterFirstUnlockThisDeviceOnly`: readable after the first unlock since boot, never
/// migrated to another device, never in iCloud Keychain, never tied to biometry. It holds
/// the mail password and nothing else.
nonisolated struct ValetMailSecretStorage: MailSecretStorage, @unchecked Sendable {
    private let valet = Valet.valet(
        with: Identifier(nonEmpty: MailConstants.valetIdentifier)!,
        accessibility: .afterFirstUnlockThisDeviceOnly
    )

    func save(_ value: String, forKey key: String) throws { try valet.setString(value, forKey: key) }
    func load(forKey key: String) -> String? { try? valet.string(forKey: key) }
    func delete(forKey key: String) { try? valet.removeObject(forKey: key) }
    func deleteAll() { try? valet.removeAllObjects() }
}

nonisolated struct MailCredentialStore: Sendable {
    static let passwordKey = "school_mail_password"

    private let storage: any MailSecretStorage

    init(storage: any MailSecretStorage = ValetMailSecretStorage()) {
        self.storage = storage
    }

    func savePassword(_ password: String) throws { try storage.save(password, forKey: Self.passwordKey) }
    func password() -> String? { storage.load(forKey: Self.passwordKey) }
    func clear() { storage.deleteAll() }
}
#endif
