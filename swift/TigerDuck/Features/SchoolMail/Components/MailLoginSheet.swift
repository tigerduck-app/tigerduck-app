#if os(iOS)
import SwiftUI

/// School Mail's sign-in, in the same `LoginSheet` the NTUST and library rows use.
struct MailLoginSheet: View {
    /// The "forgot your password" link goes to Mail2000 webmail, which is where an NTUST mail
    /// password is actually reset. A stored property rather than a literal inside `body` so a
    /// test can assert the sheet's real footer, not just that a `FooterLink` round-trips the
    /// URL it was handed.
    static var resetPasswordLink: LoginSheet.FooterLink {
        LoginSheet.FooterLink(
            title: String(localized: "school_mail_forgot_password"),
            url: MailConstants.webmailURL
        )
    }

    /// See `MailLoginCard.usernameIsAnAddress` — the same question, for the re-auth sheet.
    static var usernameIsAnAddress: Bool {
        #if DEBUG
        return MailServerConfig.effective.isOverridden
        #else
        return false
        #endif
    }

    /// `@domain` for an overridden server, so the sheet starts with the shape it expects rather
    /// than an empty field labelled "student ID". Empty against the school, where a bare ID is
    /// correct and the app supplies the domain itself. See `MailLoginCard.prefilledDomainSuffix`.
    static var initialUsername: String {
        #if DEBUG
        let config = MailServerConfig.effective
        return config.isOverridden ? "@\(config.addressDomain)" : ""
        #else
        return ""
        #endif
    }

    /// The two fields this sheet opens with, from the same decision the signed-out card uses.
    ///
    /// `currentID`/`currentPassword` are empty because that is the literal truth here: the sheet
    /// is rebuilt from scratch every time it is presented, which is exactly why the rejected
    /// password had to be remembered somewhere that outlives it.
    static func initialFields(storedID: String?, storedPassword: String?, lastRejected: String?)
        -> MailCredentialPrefill.Fields {
        MailCredentialPrefill.fields(
            storedID: storedID,
            storedPassword: storedPassword,
            currentID: "",
            currentPassword: "",
            isOverridden: usernameIsAnAddress,
            lastRejectedPassword: lastRejected,
            domainSuffix: initialUsername
        )
    }

    @Binding var isPresented: Bool
    @Environment(AppState.self) private var appState
    private let account = MailAccountManager.shared

    var body: some View {
        // Prefilled from the NTUST sign-in for the user to submit or correct, never submitted
        // automatically, never the school's password while the developer override is on, and
        // never a password this server has already rejected — `MailCredentialPrefill` owns all
        // of that and explains why.
        let prefill = Self.initialFields(
            storedID: appState.authService.storedStudentId,
            storedPassword: appState.authService.storedPassword,
            lastRejected: account.lastRejectedPassword
        )
        return LoginSheet(
            title: String(localized: "school_mail_account_title"),
            subtitle: String(localized: "school_mail_sign_in_note"),
            usernamePlaceholder: Self.usernameIsAnAddress
                ? "you\(Self.initialUsername)"
                : String(localized: "sign_in_student_id"),
            passwordPlaceholder: String(localized: "sign_in_password"),
            initialUsername: prefill.id,
            initialPassword: prefill.password,
            isLoggingIn: account.isLoggingIn,
            loginError: account.loginError?.message,
            footerLink: Self.resetPasswordLink,
            // The school takes a student ID; a DEBUG developer override can point this at a
            // server whose usernames are addresses, which must not be upper-cased as they are
            // typed. False in every Release build.
            usernameIsAnAddress: Self.usernameIsAnAddress,
            onLogin: { studentID, password in
                Task {
                    await account.login(studentID: studentID, password: password)
                    if account.isLoggedIn, account.loginError == nil {
                        isPresented = false
                    }
                }
            },
            onDismiss: {
                account.clearLoginError()
                isPresented = false
            }
        )
    }
}
#endif
