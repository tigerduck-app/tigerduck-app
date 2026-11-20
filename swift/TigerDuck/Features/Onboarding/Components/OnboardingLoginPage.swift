import SwiftUI

struct OnboardingLoginPage: View {
    enum Field { case studentId, password }

    @Binding var studentId: String
    @Binding var password: String
    var focusedField: FocusState<Field?>.Binding
    let onSkip: () -> Void
    let onSignedIn: () -> Void

    @Environment(AppEnvironment.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var showEndpointSheet = false

    var body: some View {
        OnboardingPageView(
            icon: "person.badge.key.fill",
            title: String(localized: "onboarding_sign_in_title"),
            subtitle: String(localized: "onboarding_sign_in_subtitle"),
            accentColor: .green,
            content: { credentialsForm },
            actions: { actions }
        )
        .sheet(isPresented: $showEndpointSheet) {
            NavigationStack {
                DebugEndpointView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "action_done")) { showEndpointSheet = false }
                        }
                    }
            }
        }
    }

    private var credentialsForm: some View {
        VStack(spacing: TigerDuckTheme.Spacing.md) {
            VStack(spacing: 1) {
                HStack(spacing: TigerDuckTheme.Spacing.md) {
                    Image(systemName: "person.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    TextField(String(localized: "sign_in_student_id"), text: $studentId)
                        .keyboardType(.asciiCapable)
                        .focused(focusedField, equals: .studentId)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .submitLabel(.next)
                        .onSubmit { focusedField.wrappedValue = .password }
                }
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                .padding(.vertical, TigerDuckTheme.Spacing.md)
                .background(.fill.quaternary, in: .rect(topLeadingRadius: TigerDuckTheme.CornerRadius.md, topTrailingRadius: TigerDuckTheme.CornerRadius.md))

                Divider()
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)

                HStack(spacing: TigerDuckTheme.Spacing.md) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    PasswordField(
                        placeholder: String(localized: "sign_in_password"),
                        text: $password,
                        focusBinding: focusedField,
                        focusValue: .password,
                        onSubmit: { submitLogin() }
                    )
                }
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                .padding(.vertical, TigerDuckTheme.Spacing.md)
                .background(.fill.quaternary, in: .rect(bottomLeadingRadius: TigerDuckTheme.CornerRadius.md, bottomTrailingRadius: TigerDuckTheme.CornerRadius.md))
            }
            .frame(maxWidth: 320)

            if let error = app.authService.loginError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if app.authService.hasStoredCredentials {
                Label(
                    String(localized: "action_done"),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.callout.weight(.semibold))
                .foregroundStyle(.green)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: TigerDuckTheme.Spacing.md) {
            Button(String(localized: "settings_check_server_status")) {
                openURL(AppURLs.serverStatus)
            }
            .foregroundStyle(Color.textSecondary)

            Button(String(localized: "onboarding_custom_endpoint_button")) {
                showEndpointSheet = true
            }
            .foregroundStyle(Color.textSecondary)

            Button(String(localized: "onboarding_skip_for_now"), action: onSkip)
                .foregroundStyle(Color.textSecondary)

            Button {
                submitLogin()
            } label: {
                LoadingButtonLabel(
                    isLoading: app.authService.isLoggingIn,
                    tint: .white
                ) {
                    Text(String(localized: "onboarding_sign_in_button"))
                        .font(.callout.weight(.semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(studentId.isEmpty || password.isEmpty || app.authService.isLoggingIn)
        }
    }

    private func submitLogin() {
        #if canImport(UIKit)
        UIApplication.dismissKeyboard()
        #endif
        focusedField.wrappedValue = nil
        let trimmedId = studentId.trimmingCharacters(in: .whitespaces)
        let trimmedPwd = password.trimmingCharacters(in: .whitespaces)
        guard !trimmedId.isEmpty, !trimmedPwd.isEmpty, !app.authService.isLoggingIn else { return }
        Task {
            let success = await app.authService.login(
                studentId: trimmedId, password: trimmedPwd
            )
            if success { onSignedIn() }
        }
    }
}
