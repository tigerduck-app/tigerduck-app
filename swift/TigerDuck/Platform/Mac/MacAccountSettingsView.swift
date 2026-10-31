#if os(macOS)
import SwiftUI

struct MacAccountSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showSignIn = false
    @State private var confirmsSignOut = false
    @State private var signOutLines: [String] = []

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
                        Task {
                            let unsynced = await appState.signOutDeletesUnsyncedData()
                            guard appState.authService.hasStoredCredentials else { return }
                            ImportedClassTableStore.shared.requestSignOut(
                                unsyncedData: unsynced,
                                confirm: { signOutLines = $0; confirmsSignOut = true },
                                signOut: { SignOutPlan.school(appState).run() }
                            )
                        }
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
        .alert(String(localized: "action_sign_out"), isPresented: $confirmsSignOut) {
            Button(String(localized: "action_sign_out"), role: .destructive) {
                SignOutPlan.school(appState).run()
            }
            Button(String(localized: "action_cancel"), role: .cancel) {}
        } message: {
            Text(signOutLines.joined(separator: "\n"))
        }
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
