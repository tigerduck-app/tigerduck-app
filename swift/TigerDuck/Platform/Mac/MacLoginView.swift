#if os(macOS)
import SwiftUI

/// macOS-native NTUST SSO login form.
///
/// Mirrors the iOS login sheet's contract — calls
/// `AuthService.login(studentId:password:)` and surfaces
/// `authService.loginError` inline — but renders as a centered card in
/// the main window instead of as a sheet (Mac apps don't expect a modal
/// sheet on launch). On success, `AppState.backgroundSync()` fires a
/// follow-on sync so cached data is fresh by the time the user lands on
/// the sidebar.
struct MacLoginView: View {
    @Environment(AppState.self) private var appState

    /// Whether to surface the "Skip for now" escape hatch.
    ///
    /// `true` for the root login wall — first-launch users without
    /// NTUST credentials need a way past it. `false` when presented
    /// from inside the app (e.g. the Account settings re-login sheet):
    /// the user is already past the wall, so skip would only flip the
    /// already-true `didSkipMacLogin` flag and leave the sheet stuck
    /// with no visible state change.
    let showsSkipButton: Bool

    @State private var studentId = ""
    @State private var password = ""
    @State private var isPasswordVisible = false
    @FocusState private var focused: Field?

    private enum Field { case studentId, password }

    init(showsSkipButton: Bool = true) {
        self.showsSkipButton = showsSkipButton
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            VStack(spacing: 8) {
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.tint)
                Text(String(localized: "app_name"))
                    .font(.largeTitle.bold())
                Text(String(localized: "mac_sign_in_subtitle"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 14) {
                TextField(String(localized: "sign_in_student_id"), text: $studentId)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .studentId)
                    .onSubmit { focused = .password }
                    .disableAutocorrection(true)
                    .frame(maxWidth: 340)

                HStack(spacing: 6) {
                    Group {
                        if isPasswordVisible {
                            TextField(String(localized: "sign_in_password"), text: $password)
                        } else {
                            SecureField(String(localized: "sign_in_password"), text: $password)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .password)
                    .onSubmit { Task { await attemptLogin() } }
                    .disableAutocorrection(true)

                    Button {
                        isPasswordVisible.toggle()
                    } label: {
                        // Open eye = currently visible; eye.slash = hidden.
                        Image(systemName: isPasswordVisible ? "eye" : "eye.slash")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(String(localized: isPasswordVisible ? "password_hide" : "password_show"))
                }
                .frame(maxWidth: 340)
                // SecureField masks at the OS layer; plain TextField does
                // not. While the user has the password revealed, flip the
                // window's sharingType to .none so a concurrent screen
                // share / recording does not leak the plaintext.
                .screenCaptureProtected(isPasswordVisible)
            }

            if let error = appState.authService.loginError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }

            Button {
                Task { await attemptLogin() }
            } label: {
                LoadingButtonLabel(
                    isLoading: appState.authService.isLoggingIn,
                    tint: .white
                ) {
                    Text(String(localized: "action_sign_in"))
                        .frame(maxWidth: 200)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSubmit)

            // Secondary, less-prominent escape hatch so users without
            // NTUST credentials can still explore the public surfaces
            // (e.g. bulletin board). The flag is intentionally in-memory
            // only — first launch and post-logout return the user to
            // this screen, matching the desktop convention of a login
            // form on every launch until creds are saved.
            if showsSkipButton {
                Button(String(localized: "onboarding_skip_for_now")) {
                    appState.didSkipMacLogin = true
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(appState.authService.isLoggingIn)
            }

            Spacer(minLength: 0)

            Text(String(localized: "mac_sign_in_disclaimer"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focused = .studentId }
        // Whole-view capture protection. NSWindow.sharingType = .none
        // is reference-counted so the per-row reveal wrap nested inside
        // composes safely (release-order independent).
        .screenCaptureProtected()
    }

    private var canSubmit: Bool {
        !studentId.trimmingCharacters(in: .whitespaces).isEmpty &&
        !password.isEmpty &&
        !appState.authService.isLoggingIn
    }

    private func attemptLogin() async {
        guard canSubmit else { return }
        let ok = await appState.authService.login(
            studentId: studentId,
            password: password
        )
        if ok {
            appState.completeOnboarding()
        }
    }
}
#endif
