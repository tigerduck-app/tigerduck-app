#if os(iOS)
import Foundation

nonisolated enum MailCredentialPrefill {
    struct Fields: Equatable, Sendable {
        var id: String
        var password: String
    }

    static func fields(
        storedID: String?,
        storedPassword: String?,
        currentID: String,
        currentPassword: String,
        isOverridden: Bool,
        lastRejectedPassword: String?,
        domainSuffix: String = ""
    ) -> Fields {
        let storedID = storedID ?? ""
        let storedPassword = storedPassword ?? ""

        guard !isOverridden else {
            let isPrefilled = currentID.isEmpty || matches(currentID, storedID)
            return Fields(id: isPrefilled ? domainSuffix : currentID, password: "")
        }

        var id = currentID
        if id.isEmpty, !storedID.isEmpty { id = storedID }

        var password = currentPassword
        if password.isEmpty, !storedPassword.isEmpty, storedPassword != lastRejectedPassword {
            password = storedPassword
        }
        return Fields(id: id, password: password)
    }

    private static func matches(_ current: String, _ stored: String) -> Bool {
        guard !stored.isEmpty else { return false }
        return current.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(stored.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }
}
#endif
