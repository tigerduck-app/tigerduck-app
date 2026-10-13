#if os(iOS)
import Foundation

/// What the School Mail sign-in prefills from the NTUST sign-in, as one pure decision both
/// sign-in surfaces share. A Mail2000 password need not match SSO, and repeated rejected logins
/// lock the school account and its campus Wi-Fi, so this never submits and never re-offers a
/// password the server rejected (`lastRejectedPassword`). On the school server it fills only
/// empty fields, so re-seeding keeps half-typed text. Under the developer override it offers
/// nothing of the school's, so that password cannot reach another server. The override is
/// judged on every seed, because it can be switched on while a signed-out mail screen is alive.
/// See docs/decisions/0017-mail-sign-in-prefill.md.
nonisolated enum MailCredentialPrefill {
    /// The two fields, as the sign-in should hold them.
    struct Fields: Equatable, Sendable {
        var id: String
        var password: String
    }

    /// - Parameters:
    ///   - storedID: the NTUST sign-in's student ID, or nil when not signed in there.
    ///   - storedPassword: the NTUST sign-in's password. Never offered under an override.
    ///   - currentID: what the ID field holds now ("" for a field being built fresh).
    ///   - isOverridden: whether the DEBUG developer override points the app at another server.
    ///     Always false in Release, where `MailServerConfig.effective` is `.school`.
    ///   - lastRejectedPassword: `MailAccountManager.lastRejectedPassword`. Never seeded again.
    ///   - domainSuffix: `@domain` under an override, so the form shows the shape it expects.
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
            // The password always goes: it can only be the seeded school one or one typed for this
            // server, and a few lost keystrokes on a developer screen beat proving which. The ID is
            // no secret, so only the prefilled one is replaced and a half-typed username survives.
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

    /// Whether the field still holds the ID that was prefilled into it. Trimmed and case-folded
    /// because the ID field upper-cases as it is typed (`.textInputAutocapitalization(.characters)`)
    /// and a student ID is the same ID in either case — so this errs towards clearing, which for
    /// a non-secret is the harmless direction.
    private static func matches(_ current: String, _ stored: String) -> Bool {
        guard !stored.isEmpty else { return false }
        return current.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(stored.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }
}
#endif
