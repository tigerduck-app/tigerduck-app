#if os(macOS)
import SwiftUI

struct MacLoginView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL

    let showsSkipButton: Bool

    private let onSignedIn: () -> Void

    @State private var studentId = ""
    @State private var password = ""
    @State private var isPasswordVisible = false
    @State private var confirmsSwitch = false
    @State private var isSigningIn = false
    @State private var switchLines: [String] = []
    @FocusState private var focused: Field?

    private enum Field { case studentId, password }

    init(showsSkipButton: Bool = true, onSignedIn: @escaping () -> Void = {}) {
        self.showsSkipButton = showsSkipButton
        self.onSignedIn = onSignedIn
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
                Text(String(localized: "desktop_sign_in_subtitle"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 14) {
                TextField(String(localized: "sign_in_student_id"), text: $studentId)
                    .textContentType(.username)
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
                    .textContentType(.password)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .password)
                    .onSubmit { Task { await attemptLogin() } }
                    .disableAutocorrection(true)

                    Button {
                        isPasswordVisible.toggle()
                    } label: {
                        Image(systemName: isPasswordVisible ? "eye" : "eye.slash")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(String(localized: isPasswordVisible ? "password_hide" : "password_show"))
                }
                .frame(maxWidth: 340)
                // SecureField masks at the OS layer; TextField does not. While the password is
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

            VStack(spacing: 4) {
                Toggle(
                    String(localized: "settings_sync_toggle_label"),
                    isOn: Bindable(appState).cloudSyncEnabled
                )
                .toggleStyle(.switch)
                .frame(maxWidth: 280)
                Text(String(localized: "settings_sync_brief_description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            .padding(.top, 8)

            Button(String(localized: "settings_check_server_status")) {
                openURL(AppURLs.serverStatus)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)

            if showsSkipButton {
                Button(String(localized: "onboarding_skip_for_now")) {
                    appState.didSkipMacLogin = true
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(appState.authService.isLoggingIn)
            }

            Spacer(minLength: 0)

            Text(String(localized: "desktop_sign_in_disclaimer"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(String(localized: "action_sign_out"), isPresented: $confirmsSwitch) {
            Button(String(localized: "action_sign_out"), role: .destructive) { Task { await logIn() } }
            Button(String(localized: "action_cancel"), role: .cancel) {}
        } message: {
            Text(switchLines.joined(separator: "\n"))
        }
        .onAppear {
            if studentId.isEmpty, let stored = appState.authService.storedStudentId { studentId = stored }
            focused = studentId.isEmpty ? .studentId : .password
        }
        .screenCaptureProtected()
    }

    private var canSubmit: Bool {
        !studentId.trimmingCharacters(in: .whitespaces).isEmpty &&
        !password.isEmpty &&
        !appState.authService.isLoggingIn &&
        !isSigningIn
    }

    private func attemptLogin() async {
        guard canSubmit else { return }
        isSigningIn = true
        defer { isSigningIn = false }
        guard AuthService.replacesStoredAccount(
            stored: appState.authService.storedStudentId, signingInAs: studentId
        ) else { return await logIn() }
        let unsynced = await appState.signOutDeletesUnsyncedData()
        ImportedClassTableStore.shared.requestSignOut(
            unsyncedData: unsynced,
            confirm: { switchLines = $0; confirmsSwitch = true },
            signOut: { Task { await logIn() } }
        )
    }

    private func logIn() async {
        let ok = await appState.authService.login(
            studentId: studentId,
            password: password
        )
        if ok {
            appState.completeOnboarding()
            onSignedIn()
        }
    }
}
#endif
