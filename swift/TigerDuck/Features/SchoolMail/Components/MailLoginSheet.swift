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

    @Binding var isPresented: Bool
    private let account = MailAccountManager.shared

    var body: some View {
        LoginSheet(
            title: String(localized: "school_mail_account_title"),
            subtitle: String(localized: "school_mail_sign_in_note"),
            usernamePlaceholder: String(localized: "sign_in_student_id"),
            passwordPlaceholder: String(localized: "sign_in_password"),
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
