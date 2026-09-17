#if os(iOS)
import SwiftUI

/// School Mail's sign-in, in the same `LoginSheet` the NTUST and library rows use.
struct MailLoginSheet: View {
    /// 忘記密碼 → Mail2000 webmail, which is where an NTUST mail password is actually reset.
    /// A stored property rather than a literal inside `body` so a test can assert the sheet's
    /// real footer, not just that a `FooterLink` round-trips the URL it was handed.
    static var resetPasswordLink: LoginSheet.FooterLink {
        LoginSheet.FooterLink(
            title: String(localized: "school_mail_forgot_password"),
            url: MailConstants.webmailURL
        )
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
