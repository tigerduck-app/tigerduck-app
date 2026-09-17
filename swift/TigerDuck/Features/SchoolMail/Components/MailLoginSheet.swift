#if os(iOS)
import SwiftUI

/// School Mail's sign-in, in the same `LoginSheet` the NTUST and library rows use.
struct MailLoginSheet: View {
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
            footerLink: LoginSheet.FooterLink(
                title: String(localized: "school_mail_forgot_password"),
                url: MailConstants.webmailURL
            ),
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
