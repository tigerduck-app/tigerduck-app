#if os(macOS)
import SwiftUI

/// Account tab — NTUST sign-in state only: signed in with a sign-out
/// button, or signed out with a sign-in button. TigerSync has its own tab
/// (`MacTigerSyncSettingsView`). One of the tabs assembled by
/// `MacSettingsScene`.
struct MacAccountSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showSignIn = false

    var body: some View {
        Form {
            Section(String(localized: "desktop_settings_section_ntust")) {
                if appState.authService.hasStoredCredentials {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text(String(localized: "desktop_settings_signed_in_ntust"))
                    }
                    Button(role: .destructive) {
                        appState.logoutNTUST()
                    } label: {
                        Label(String(localized: "action_sign_out"), systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } else {
                    Text(String(localized: "common_not_signed_in"))
                        .foregroundStyle(.secondary)
                    Button {
                        showSignIn = true
                    } label: {
                        Label(String(localized: "action_sign_in"), systemImage: "person.badge.key.fill")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showSignIn) {
            MacLoginView(showsSkipButton: false)
                .frame(minWidth: 460, idealWidth: 520, minHeight: 520, idealHeight: 560)
                .onChange(of: appState.authService.hasStoredCredentials) { _, signedIn in
                    if signedIn { showSignIn = false }
                }
        }
    }
}

#endif
