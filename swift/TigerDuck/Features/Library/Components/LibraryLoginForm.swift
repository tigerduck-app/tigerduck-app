import SwiftUI

/// The library page's sign-in form, shown while no library account is signed in.
struct LibraryLoginForm: View {
    @Bindable var viewModel: LibraryViewModel

    @FocusState private var loginField: LoginField?
    @ScaledMetric(relativeTo: .largeTitle) private var heroIconSize: CGFloat = 56

    private enum LoginField { case username, password }

    var body: some View {
        VStack(spacing: TigerDuckTheme.Spacing.lg) {
            Image(systemName: "qrcode")
                .font(.system(size: heroIconSize))
                .foregroundStyle(.tint)

            Text(String(localized: "library_sign_in_qr_prompt"))
                .font(TigerDuckTheme.Typography.title)
                .foregroundStyle(Color.textPrimary)

            Text(String(localized: "library_password_hint"))
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)

            VStack(spacing: TigerDuckTheme.Spacing.sm) {
                TextField(String(localized: "sign_in_student_id"), text: $viewModel.libUsername)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .focused($loginField, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { loginField = .password }
                    .padding(TigerDuckTheme.Spacing.md)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.sm))

                PasswordField(
                    placeholder: String(localized: "library_sign_in_password"),
                    text: $viewModel.libPassword,
                    focusBinding: $loginField,
                    focusValue: .password,
                    onSubmit: { viewModel.loginAndStart() }
                )
                .padding(TigerDuckTheme.Spacing.md)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.sm))
            }

            loginButton
        }
        .cardPadding()
        .frame(maxWidth: .infinity)
        .glassCard()
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    @ViewBuilder
    private var loginButton: some View {
        let disabled = viewModel.libUsername.isEmpty || viewModel.libPassword.isEmpty || viewModel.isLoggingIn

        if #available(iOS 26, *) {
            Button {
                viewModel.loginAndStart()
            } label: {
                loginButtonLabel
            }
            .buttonStyle(.glassProminent)
            .disabled(disabled)
        } else {
            Button {
                viewModel.loginAndStart()
            } label: {
                loginButtonLabel
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(TigerDuckTheme.Spacing.md)
                    .background(
                        .tint.opacity(disabled ? 0.5 : 1),
                        in: RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md)
                    )
            }
            .disabled(disabled)
        }
    }

    private var loginButtonLabel: some View {
        HStack(spacing: TigerDuckTheme.Spacing.sm) {
            if viewModel.isLoggingIn {
                ProgressView()
                    .tint(.white)
            }
            Text(viewModel.isLoggingIn
                ? String(localized: "library_signing_in_label")
                : String(localized: "library_sign_in_action"))
                .font(TigerDuckTheme.Typography.headline)
        }
    }
}
