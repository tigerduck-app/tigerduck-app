#if os(iOS)
import SwiftUI

struct MailLoginSheet: View {
    static var resetPasswordLink: LoginSheet.FooterLink {
        LoginSheet.FooterLink(
            title: String(localized: "school_mail_forgot_password"),
            url: MailConstants.webmailURL
        )
    }

    static var usernameIsAnAddress: Bool {
        #if DEBUG
        return MailServerConfig.effective.isOverridden
        #else
        return false
        #endif
    }

    static var initialUsername: String {
        #if DEBUG
        let config = MailServerConfig.effective
        return config.isOverridden ? "@\(config.addressDomain)" : ""
        #else
        return ""
        #endif
    }

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
        .linkRouting()
    }
}
#endif
