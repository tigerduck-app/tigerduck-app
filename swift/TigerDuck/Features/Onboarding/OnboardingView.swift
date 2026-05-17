import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @State private var currentPage = 0
    @State private var studentId = ""
    @State private var password = ""
    @FocusState private var focusedField: Field?

    private enum Field { case studentId, password }

    var body: some View {
        TabView(selection: $currentPage) {
            // Page 1: Welcome
            OnboardingPageView(
                icon: "graduationcap.fill",
                title: String(localized: "onboarding_welcome_title"),
                subtitle: String(localized: "onboarding_welcome_subtitle"),
                accentColor: .accentPrimary
            ) {
                Button(String(localized: "action_next")) {
                    withAnimation { currentPage = 1 }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .tag(0)

            // Page 2: Login
            OnboardingPageView(
                icon: "person.badge.key.fill",
                title: String(localized: "onboarding_login_title"),
                subtitle: String(localized: "onboarding_login_subtitle"),
                accentColor: .green
            ) {
                VStack(spacing: TigerDuckTheme.Spacing.lg) {
                    VStack(spacing: 1) {
                        HStack(spacing: TigerDuckTheme.Spacing.md) {
                            Image(systemName: "person.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            TextField(String(localized: "login_student_id"), text: $studentId)
                                .keyboardType(.asciiCapable)
                                .focused($focusedField, equals: .studentId)
                                .textContentType(.username)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.characters)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .password }
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
                                placeholder: String(localized: "login_password"),
                                text: $password,
                                focusBinding: $focusedField,
                                focusValue: .password,
                                onSubmit: {
                                    let trimmedId = studentId.trimmingCharacters(in: .whitespaces)
                                    let trimmedPwd = password.trimmingCharacters(in: .whitespaces)
                                    guard !trimmedId.isEmpty, !trimmedPwd.isEmpty, !appState.authService.isLoggingIn else { return }
                                    Task {
                                        let success = await appState.authService.login(studentId: trimmedId, password: trimmedPwd)
                                        if success { withAnimation { currentPage = 2 } }
                                    }
                                }
                            )
                        }
                        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                        .padding(.vertical, TigerDuckTheme.Spacing.md)
                        .background(.fill.quaternary, in: .rect(bottomLeadingRadius: TigerDuckTheme.CornerRadius.md, bottomTrailingRadius: TigerDuckTheme.CornerRadius.md))
                    }
                    .frame(maxWidth: 320)

                    Spacer()
                        .frame(height: TigerDuckTheme.Spacing.lg)

                    if let error = appState.authService.loginError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Button(String(localized: "onboarding_skip_for_now")) {
                        withAnimation { currentPage = 2 }
                    }
                    .foregroundStyle(Color.textSecondary)

                    Button {
                        focusedField = nil
                        let trimmedId = studentId.trimmingCharacters(in: .whitespaces)
                        let trimmedPwd = password.trimmingCharacters(in: .whitespaces)
                        Task {
                            let success = await appState.authService.login(
                                studentId: trimmedId,
                                password: trimmedPwd
                            )
                            if success {
                                withAnimation { currentPage = 2 }
                            }
                        }
                    } label: {
                        if appState.authService.isLoggingIn {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text(String(localized: "onboarding_login_button"))
                                .font(.callout.weight(.semibold))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(studentId.isEmpty || password.isEmpty || appState.authService.isLoggingIn)
                }
            }
            .tag(1)

            // Page 3: Feature selection
            OnboardingPageView(
                icon: "slider.horizontal.3",
                title: String(localized: "onboarding_choose_features_title"),
                subtitle: String(localized: "onboarding_choose_features_subtitle"),
                accentColor: .orange
            ) {
                Button(String(localized: "action_next")) {
                    withAnimation { currentPage = 3 }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .tag(2)

            // Page 4: Done
            OnboardingPageView(
                icon: "checkmark.circle.fill",
                title: String(localized: "onboarding_ready_title"),
                subtitle: String(localized: "onboarding_ready_subtitle"),
                accentColor: .accentPrimary
            ) {
                Button(String(localized: "onboarding_start_button")) {
                    appState.completeOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                // Block "Start" while a login is still in flight on the
                // previous page. Otherwise a user who advances mid-login
                // (or while backgrounded) lands on the home screen
                // logged-out, with onboarding already marked done — and
                // has to discover the Settings → re-login path manually.
                .disabled(appState.authService.isLoggingIn)
            }
            .tag(3)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .background(Color.backgroundPrimary)
        .contentShape(Rectangle())
        .onTapGesture { focusedField = nil }
        .onChange(of: currentPage) { _, _ in focusedField = nil }
    }
}

