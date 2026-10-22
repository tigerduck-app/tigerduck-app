import SwiftUI
#if os(iOS)
import UIKit
#endif

struct LibrarySettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        List {
            Section {
                Toggle(
                    String(localized: "settings_flip_to_library_title"),
                    isOn: Self.flipSwitch($appState.flipToLibraryEnabled, signedIn: appState.isLibraryLoggedIn)
                )
                .disabled(!appState.isLibraryLoggedIn)
            } footer: {
                Text(String(localized: "settings_flip_to_library_summary"))
            }
        }
        .navigationTitle(String(localized: "settings_library_related_features"))
        .navigationBarTitleDisplayMode(.inline)
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
