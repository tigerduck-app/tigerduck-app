import SwiftUI
#if os(iOS)
import UIKit
#endif

struct LibrarySettingsView: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(AppEnvironment.self) private var app: AppEnvironment?
    @Environment(\.settingsState) private var state

    var body: some View {
        @Bindable var preferences = preferences
        List {
            if SettingsRow.flipToLibrary.isShown(in: state) {
                Section {
                    Toggle(
                        SettingsRow.flipToLibrary.label,
                        isOn: Self.flipSwitch($preferences.flipToLibraryEnabled, signedIn: state.library.isSignedIn)
                    )
                    .settingsRow(.flipToLibrary)
                } footer: {
                    Text(String(localized: "settings_flip_to_library_summary"))
                }
            }
            if SettingsRow.librarySignOut.isShown(in: state) {
                Section {
                    Button(SettingsRow.librarySignOut.label, role: .destructive) {
                        app?.library.logout()
                    }
                }
            }
        }
    }

    static func flipSwitch(_ enabled: Binding<Bool>, signedIn: Bool) -> Binding<Bool> {
        guard signedIn else { return .constant(false) }
        return Binding(
            get: { enabled.wrappedValue },
            set: { value in
                #if os(iOS)
                FirstTriggerPromptCenter.shared.markSeen(.flipToLibrary)
                #endif
                enabled.wrappedValue = value
            }
        )
    }

    static var isAvailable: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone && FlipDetector.isSupported
        #else
        false
        #endif
    }
}
