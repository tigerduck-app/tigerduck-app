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

    /// The password this sheet opens with: the NTUST one, unless the override is on (it is not
    /// the school's server's to have) or the mail server has already rejected it (§7.4 — see
    /// `MailAccountManager.lastRejectedPassword`). A stored function rather than an expression
    /// inside `body` so the rule is testable without standing the sheet up.
    static func initialPassword(stored: String?, lastRejected: String?) -> String {
        guard !usernameIsAnAddress, let stored, !stored.isEmpty, stored != lastRejected else { return "" }
        return stored
    }

    @Binding var isPresented: Bool
    @Environment(AppState.self) private var appState
    private let account = MailAccountManager.shared

    var body: some View {
        LoginSheet(
            title: String(localized: "school_mail_account_title"),
            subtitle: String(localized: "school_mail_sign_in_note"),
            usernamePlaceholder: Self.usernameIsAnAddress
                ? "you\(Self.initialUsername)"
                : String(localized: "sign_in_student_id"),
            passwordPlaceholder: String(localized: "sign_in_password"),
            initialUsername: Self.initialUsername.isEmpty
                ? (appState.authService.storedStudentId ?? "")
                : Self.initialUsername,
            // Prefilled from the NTUST sign-in for the user to submit or correct, never
            // submitted automatically — see `MailLoginCard.seedFromNTUSTAccount`. Skipped while
            // the developer override is on, because the school's password is not for someone
            // else's server, and skipped once the server has rejected it: dismissing and
            // reopening this sheet builds a fresh `LoginSheet` every time, so without that a
            // rejected password came straight back and another rejected `LOGIN` was one tap
            // away — see `MailAccountManager.lastRejectedPassword` and §7.4.
            initialPassword: Self.initialPassword(
                stored: appState.authService.storedPassword,
                lastRejected: account.lastRejectedPassword
            ),
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
