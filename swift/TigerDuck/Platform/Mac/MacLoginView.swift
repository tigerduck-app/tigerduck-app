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

    @State private var studentId = ""
    @State private var password = ""
    @State private var isPasswordVisible = false
    @FocusState private var focused: Field?

    private enum Field { case studentId, password }

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            VStack(spacing: 8) {
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.tint)
                Text("TigerDuck")
                    .font(.largeTitle.bold())
                Text("Sign in with your NTUST SSO account")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 14) {
                TextField("Student ID", text: $studentId)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .studentId)
                    .onSubmit { focused = .password }
                    .disableAutocorrection(true)
                    .frame(maxWidth: 340)

                HStack(spacing: 6) {
                    Group {
                        if isPasswordVisible {
                            TextField("Password", text: $password)
                        } else {
                            SecureField("Password", text: $password)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .password)
                    .onSubmit { Task { await attemptLogin() } }
                    .disableAutocorrection(true)

                    Button {
                        isPasswordVisible.toggle()
                    } label: {
                        Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isPasswordVisible ? "Hide password" : "Show password")
                }
                .frame(maxWidth: 340)
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
                if appState.authService.isLoggingIn {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: 200)
                } else {
                    Text("Sign in")
                        .frame(maxWidth: 200)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSubmit)

            Spacer(minLength: 0)

            Text("This app is not affiliated with National Taiwan University of Science and Technology.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focused = .studentId }
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
            appState.backgroundSync()
        }
    }
}
#endif
