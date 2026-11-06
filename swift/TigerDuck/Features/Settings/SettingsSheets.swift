import SwiftUI

/// The sheets and alerts hang on the list, not on the rows that open them, which a list may
/// unload while one shows.
@Observable
final class SettingsSheetState {
    var showingTabEditor = false
    var showingAccentEditor = false
    var showLibraryLogin = false
    var confirmsSignOut = false
    var signOutLines: [String] = []
    var libIsLoggingIn = false
    var libLoginError: String?
    #if os(iOS)
    var showSchoolMailLogin = false
    var showManualUpdateCheckResultAlert = false
    var manualWhatsNewItem: WhatsNewPresentation?
    #endif
}

struct SettingsSheets: ViewModifier {
    @Bindable var state: SettingsSheetState

    @Environment(AppEnvironment.self) private var app
    @Environment(AppPreferences.self) private var preferences

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $state.showingTabEditor) {
                TabEditorView()
            }
            .sheet(isPresented: $state.showingAccentEditor) {
                AccentGradientEditor(preferences: preferences)
            }
            .alert(String(localized: "action_sign_out"), isPresented: $state.confirmsSignOut) {
                Button(String(localized: "action_sign_out"), role: .destructive) {
                    SignOutPlan.school(app).run()
                }
                Button(String(localized: "action_cancel"), role: .cancel) {}
            } message: {
                Text(state.signOutLines.joined(separator: "\n"))
            }
            .sheet(isPresented: $state.showLibraryLogin) {
                LoginSheet(
                    title: String(localized: "settings_account_library_system"),
                    subtitle: String(localized: "settings_library_account_subtitle"),
                    usernamePlaceholder: String(localized: "sign_in_student_id"),
                    passwordPlaceholder: String(localized: "sign_in_password"),
                    initialUsername: app.authService.storedStudentId ?? "",
                    isLoggingIn: state.libIsLoggingIn,
                    loginError: state.libLoginError,
                    onLogin: { username, password in
                        Task {
                            state.libIsLoggingIn = true
                            state.libLoginError = nil
                            do {
                                try await LibraryAccount.signIn(
                                    username: username,
                                    password: password
                                )
                                app.library.noteChange()
                                state.showLibraryLogin = false
                            } catch {
                                state.libLoginError = error.localizedDescription
                            }
                            state.libIsLoggingIn = false
                        }
                    },
                    onDismiss: {
                        state.showLibraryLogin = false
                        state.libLoginError = nil
                    }
                )
            }
            #if os(iOS)
            .sheet(isPresented: $state.showSchoolMailLogin) {
                MailLoginSheet(isPresented: $state.showSchoolMailLogin)
            }
            .alert(
                manualCheckResultAlertTitle,
                isPresented: $state.showManualUpdateCheckResultAlert,
                actions: {
                    Button(String(localized: "action_got_it"), role: .cancel) {
                        app.updateNotifyCoordinator.lastManualCheckResult = nil
                    }
                },
                message: {
                    Text(manualCheckResultAlertMessage)
                }
            )
            .sheet(item: $state.manualWhatsNewItem) { presentation in
                WhatsNewFlowView(presentation: presentation) {
                    state.manualWhatsNewItem = nil
                }
                .whatsNewSheetPresentation()
            }
            #endif
    }

    #if os(iOS)
    private var manualCheckResultAlertTitle: String {
        switch app.updateNotifyCoordinator.lastManualCheckResult {
        case .upToDate: return String(localized: "update_up_to_date_title")
        case .failed: return String(localized: "update_check_failed_title")
        case .offered, nil: return ""
        }
    }

    private var manualCheckResultAlertMessage: String {
        switch app.updateNotifyCoordinator.lastManualCheckResult {
        case .upToDate:
            return String(format: NSLocalizedString(
                "update_up_to_date_message",
                comment: ""
            ), AppConstants.appName)
        case .failed:
            return String(localized: "update_check_failed_message")
        case .offered, nil:
            return ""
        }
    }
    #endif
}
