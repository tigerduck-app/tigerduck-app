#if os(iOS)
import SwiftUI

struct MailLoginCard: View {
    private enum Field: Hashable { case studentID, password }

    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @State private var studentID = ""
    @State private var password = ""
    @FocusState private var field: Field?
    @ScaledMetric(relativeTo: .largeTitle) private var heroIconSize: CGFloat = 36
    private let account = MailAccountManager.shared

    private var prefilledDomainSuffix: String {
        #if DEBUG
        let config = MailServerConfig.effective
        return config.isOverridden ? "@\(config.addressDomain)" : ""
        #else
        return ""
        #endif
    }

    private var usernamePlaceholder: String {
        prefilledDomainSuffix.isEmpty
            ? String(localized: "sign_in_student_id")
            : "you\(prefilledDomainSuffix)"
    }

    private var usernameIsAnAddress: Bool {
        #if DEBUG
        return MailServerConfig.effective.isOverridden
        #else
        return false
        #endif
    }

    var body: some View {
        VStack(spacing: TigerDuckTheme.Spacing.lg) {
            Image(systemName: "envelope.fill")
                .font(.system(size: heroIconSize))
                .foregroundStyle(.tint)

            Text(String(localized: "school_mail_sign_in_prompt_title"))
                .font(TigerDuckTheme.Typography.title)
                .foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.center)

            VStack(spacing: TigerDuckTheme.Spacing.sm) {
                TextField(usernamePlaceholder, text: $studentID)
                    .textContentType(usernameIsAnAddress ? .emailAddress : .username)
                    .autocorrectionDisabled()
                    // `.characters` suits a student ID (`B10000000`) but upper-cases an address as
                    // it is typed, and `MailAccountManager.normalizedUsername` keeps an address's
                    // case (RFC 5321 §2.3.11), so the login would go out upper-cased and fail.
                    .textInputAutocapitalization(usernameIsAnAddress ? .never : .characters)
                    .keyboardType(usernameIsAnAddress ? .emailAddress : .default)
                    .focused($field, equals: .studentID)
                    .submitLabel(.next)
                    .onSubmit { field = .password }
                    .padding(TigerDuckTheme.Spacing.md)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.sm))

                PasswordField(
                    placeholder: String(localized: "sign_in_password"),
                    text: $password,
                    focusBinding: $field,
                    focusValue: .password,
                    onSubmit: submit
                )
                .padding(TigerDuckTheme.Spacing.md)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.sm))
            }

            Text(String(localized: "school_mail_sign_in_note"))
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)

            if let error = account.loginError {
                Label(error.message, systemImage: "xmark.circle")
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(.red)
            }

            signInButton

            Button(String(localized: "school_mail_forgot_password")) { openURL(MailConstants.webmailURL) }
                .font(TigerDuckTheme.Typography.caption)
        }
        .cardPadding()
        .frame(maxWidth: .infinity)
        .glassCard()
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .onAppear { seedFields() }
        #if DEBUG
        .onChange(of: DevMailServerSettings.shared.generation) { _, _ in seedFields() }
        #endif
    }

    private func seedFields() {
        let auth = appState.authService
        let fields = MailCredentialPrefill.fields(
            storedID: auth.storedStudentId,
            storedPassword: auth.storedPassword,
            currentID: studentID,
            currentPassword: password,
            isOverridden: usernameIsAnAddress,
            lastRejectedPassword: account.lastRejectedPassword,
            domainSuffix: prefilledDomainSuffix
        )
        studentID = fields.id
        password = fields.password
    }

    @ViewBuilder
    private var signInButton: some View {
        let disabled = studentID.isEmpty || password.isEmpty || account.isLoggingIn
        let label = LoadingButtonLabel(isLoading: account.isLoggingIn) {
            Text(String(localized: "action_sign_in"))
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
        }
        if #available(iOS 26, *) {
            Button(action: submit) { label }.buttonStyle(.glassProminent).disabled(disabled)
        } else {
            Button(action: submit) { label }.buttonStyle(.borderedProminent).disabled(disabled)
        }
    }

    private func submit() {
        guard !studentID.isEmpty, !password.isEmpty, !account.isLoggingIn else { return }
        field = nil
        let id = studentID
        let secret = password
        Task {
            await account.login(studentID: id, password: secret)
            if account.isLoggedIn { password = "" }
        }
    }
}
#endif
