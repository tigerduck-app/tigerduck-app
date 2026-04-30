import SwiftUI

/// View modifier that attaches the app-level NTUST login sheet. Applied once
/// at the app root so any surface that calls ``AppState/presentNTUSTLogin()``
/// triggers the same flow — Home, Class Table, Settings, and any future
/// protected entry point share one presenter, one error surface, and one
/// post-login refresh path.
struct NTUSTLoginSheetHost: ViewModifier {
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        @Bindable var appState = appState

        content.sheet(isPresented: $appState.isShowingNTUSTLoginSheet) {
            LoginSheet(
                title: String(localized: "settings_account_ntust_system"),
                subtitle: String(localized: "onboarding_login_subtitle"),
                usernamePlaceholder: String(localized: "login_student_id"),
                passwordPlaceholder: String(localized: "login_password"),
                isLoggingIn: appState.authService.isLoggingIn,
                loginError: appState.authService.loginError,
                onLogin: { studentId, password in
                    Task {
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
                onDismiss: { appState.dismissNTUSTLogin() }
            )
        }
    }
}

extension View {
    /// Attach the shared NTUST login sheet presenter. Must be applied once
    /// above any surface that calls ``AppState/presentNTUSTLogin()``.
    func ntustLoginSheetHost() -> some View {
        modifier(NTUSTLoginSheetHost())
    }
}
