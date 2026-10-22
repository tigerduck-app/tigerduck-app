import SwiftUI

struct NTUSTLoginSheetHost: ViewModifier {
    @Environment(AppState.self) private var appState
    @State private var signIn: Task<Void, Never>?

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
                onLogin: { studentId, password in
                    signIn = Task {
                        _ = await appState.authService.login(
                            studentId: studentId,
                            password: password
                        )
                        if appState.isNTUSTLoggedIn {
                            appState.dismissNTUSTLogin()
                            appState.notifyLibraryStateChanged()
                            appState.backgroundSync()
                        }
                    }
                },
                onDismiss: {
                    signIn?.cancel()
                    appState.dismissNTUSTLogin()
                }
            )
        }
    }
}

extension View {
    func ntustLoginSheetHost() -> some View {
        modifier(NTUSTLoginSheetHost())
    }
}
