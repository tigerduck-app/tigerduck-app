import SwiftUI

struct NTUSTLoginSheetHost: ViewModifier {
    @Environment(AppEnvironment.self) private var app
    @State private var signIn: Task<Void, Never>?
    @State private var isSigningIn = false
    @State private var confirmsSwitch = false
    @State private var switchLines: [String] = []
    @State private var switchAccount: () -> Void = {}

    func body(content: Content) -> some View {
        @Bindable var router = app.router

        content.sheet(isPresented: $router.isShowingNTUSTLoginSheet) {
            LoginSheet(
                title: String(localized: "settings_account_ntust_system"),
                subtitle: String(localized: "onboarding_sign_in_subtitle"),
                usernamePlaceholder: String(localized: "sign_in_student_id"),
                passwordPlaceholder: String(localized: "sign_in_password"),
                initialUsername: app.authService.storedStudentId ?? "",
                isLoggingIn: app.authService.isLoggingIn,
                loginError: app.authService.loginError,
                onLogin: requestSignIn,
                onDismiss: {
                    signIn?.cancel()
                    app.router.dismissNTUSTLogin()
                }
            )
            .alert(String(localized: "sign_in_change_account_title"), isPresented: $confirmsSwitch) {
                Button(String(localized: "action_change"), role: .destructive) { switchAccount() }
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
                stored: app.authService.storedStudentId, signingInAs: studentId
            ) else { return await logIn(studentId, password) }
            let unsynced = await app.signOutCheck.deletesUnsyncedData()
            guard !Task.isCancelled else { return }
            ImportedClassTableStore.shared.requestSignOut(
                unsyncedData: unsynced,
                confirm: { switchLines = $0; switchAccount = go; confirmsSwitch = true },
                signOut: go
            )
        }
    }

    private func logIn(_ studentId: String, _ password: String) async {
        _ = await app.authService.login(studentId: studentId, password: password)
        if app.authService.isNTUSTAuthenticated {
            app.router.dismissNTUSTLogin()
            app.library.noteChange()
            app.activation.refresh()
        }
    }
}

extension View {
    func ntustLoginSheetHost() -> some View {
        modifier(NTUSTLoginSheetHost())
    }
}
