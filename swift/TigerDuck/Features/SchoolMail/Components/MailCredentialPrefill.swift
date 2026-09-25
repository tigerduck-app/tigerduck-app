#if os(iOS)
import Foundation

/// What the School Mail sign-in prefills, as one pure decision both sign-in surfaces share.
///
/// §7.1 keeps the mail login separate from the NTUST one — a Mail2000 password is set in
/// webmail and need not match SSO — and this screen used to prefill nothing at all. The user
/// asked for the prefill anyway, knowing that: for the many students who use the same password
/// it removes the only typing the screen asks for. It comes with three carve-outs, and they are
/// the whole reason this is a value-returning function rather than a few lines inside a view:
///
/// - **It never submits.** Nothing here calls `MailAccountManager.login`; it returns the two
///   strings the fields should hold and the user taps Sign in, or does not. That is what keeps
///   §7.4 intact — repeated rejected logins lock the school account *and its campus Wi-Fi*, so a
///   wrong guess is only ever sent because someone chose to send it.
/// - **Nothing of the school's is offered while the developer override is on.** The stored
///   password belongs to the school account and must not reach somebody else's server, which is
///   the same rule `DevMailConnectionProbe.credentials(username:password:appliedIsOverridden:)`
///   applies to the diagnostic. This is decided from the override's state *every time the fields
///   are seeded*, not once when the screen first appeared: the override can be switched on from
///   Settings while a signed-out mail screen is still alive behind it, and a prefill that only
///   held at first appearance left the school's password sitting in a form that now points
///   somewhere else, one tap from being sent there.
/// - **It only ever fills an empty field**, so re-seeding cannot overwrite something half-typed.
///
/// And one rule the carve-outs imply but did not state: a password the server has already
/// **rejected** is never offered again (`lastRejectedPassword`). A mismatch between the SSO and
/// Mail2000 passwords is the *expected* failure here, and without this, dismissing and
/// reopening the sign-in put the same rejected password back in the field — making another
/// rejected `LOGIN` a single tap on precisely the path §7.4 exists to protect.
nonisolated enum MailCredentialPrefill {
    /// The two fields, as the sign-in should hold them.
    struct Fields: Equatable, Sendable {
        var id: String
        var password: String
    }

    /// - Parameters:
    ///   - storedID: the NTUST sign-in's student ID, or nil when not signed in there.
    ///   - storedPassword: the NTUST sign-in's password. **Never** offered under an override.
    ///   - currentID: what the ID field holds right now ("" for a field being built fresh).
    ///   - currentPassword: what the password field holds right now.
    ///   - isOverridden: whether the DEBUG developer override points the app at another server.
    ///     Always false in a Release build — `MailServerConfig.effective.isOverridden` has no
    ///     branch there that could return anything else.
    ///   - lastRejectedPassword: the password the mail server most recently rejected, from
    ///     `MailAccountManager.lastRejectedPassword`. Never seeded again.
    ///   - domainSuffix: `@domain` for an overridden server, so the form shows the shape it
    ///     expects instead of an empty field labelled "student ID". Empty against the school,
    ///     where a bare ID is right and the app supplies the domain itself.
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
            // The password goes unconditionally: the only one that can be in there is the
            // school's (nothing else is ever seeded) or one typed for this server, and losing a
            // few typed characters on a developer screen is not worth the branch that would
            // have to prove which of the two it is.
            //
            // The ID is not a secret, so it is only replaced when it is the one that was
            // prefilled — a half-typed username survives, which is carve-out (c).
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
