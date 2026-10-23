import SwiftUI

struct NTUSTLoginSheetHost: ViewModifier {
    @Environment(AppState.self) private var appState
    @State private var signIn: Task<Void, Never>?
    @State private var isSigningIn = false
    @State private var confirmsSwitch = false
    @State private var switchLines: [String] = []
    @State private var switchAccount: () -> Void = {}

    func body(content: Content) -> some View {
        @Bindable var appState = appState

        content.sheet(isPresented: $appState.isShowingNTUSTLoginSheet) {
            LoginSheet(
                title: String(localized: "settings_account_ntust_system"),
                subtitle: String(localized: "onboarding_sign_in_subtitle"),
                usernamePlaceholder: String(localized: "sign_in_student_id"),
                passwordPlaceholder: String(localized: "sign_in_password"),
                initialUsername: appState.authService.storedStudentId ?? "",
                isLoggingIn: appState.authService.isLoggingIn,
                loginError: appState.authService.loginError,
                onLogin: requestSignIn,
                onDismiss: {
                    signIn?.cancel()
                    appState.dismissNTUSTLogin()
                }
            )
            .alert(String(localized: "action_sign_out"), isPresented: $confirmsSwitch) {
                Button(String(localized: "action_sign_out"), role: .destructive) { switchAccount() }
                Button(String(localized: "action_cancel"), role: .cancel) {}
            } message: {
                Text(switchLines.joined(separator: "\n"))
            }
        }
    }

    private func requestSignIn(_ studentId: String, _ password: String) {
        guard !isSigningIn else { return }
        isSigningIn = true
        let go = { signIn = Task { await logIn(studentId, password) } }
        signIn = Task {
            defer { isSigningIn = false }
            guard AuthService.replacesStoredAccount(
                stored: appState.authService.storedStudentId, signingInAs: studentId
            ) else { return await logIn(studentId, password) }
            let unsynced = await appState.signOutDeletesUnsyncedData()
            guard !Task.isCancelled else { return }
            ImportedClassTableStore.shared.requestSignOut(
                unsyncedData: unsynced,
                confirm: { switchLines = $0; switchAccount = go; confirmsSwitch = true },
                signOut: go
            )
        }
    }

    private func logIn(_ studentId: String, _ password: String) async {
        _ = await appState.authService.login(studentId: studentId, password: password)
        if appState.isNTUSTLoggedIn {
            appState.dismissNTUSTLogin()
            appState.notifyLibraryStateChanged()
            appState.backgroundSync()
        }
    }
}

extension View {
    func ntustLoginSheetHost() -> some View {
        modifier(NTUSTLoginSheetHost())
    }
}
