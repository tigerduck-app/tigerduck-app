#if os(iOS)
import Foundation
import Valet

nonisolated protocol MailSecretStorage: Sendable {
    func save(_ value: String, forKey key: String) throws
    func load(forKey key: String) -> String?
    func delete(forKey key: String)
    func deleteAll()
}

/// New-mail checks run from Background App Refresh, usually while the phone is locked, so this
/// Valet uses `.afterFirstUnlockThisDeviceOnly`.
nonisolated struct ValetMailSecretStorage: MailSecretStorage, @unchecked Sendable {
    private let valet: Valet

    init(identifier: String = MailConstants.valetIdentifier) {
        valet = Valet.valet(
            with: Identifier(nonEmpty: identifier)!,
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
    }

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

    func savePassword(_ password: String, for signIn: SignIn) throws {
        guard signIn.isCurrent else { return }
        try storage.save(password, forKey: Self.passwordKey)
    }
    func password() -> String? { storage.load(forKey: Self.passwordKey) }
    func clear() { storage.deleteAll() }
}

extension MailCredentialStore: AccountScoped {
    @MainActor static func forgetAccount(in storage: AccountStorage) {
        storage.mailCredentials.clear()
    }
}
#endif
