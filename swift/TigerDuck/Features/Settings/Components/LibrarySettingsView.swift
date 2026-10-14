import SwiftUI
#if os(iOS)
import UIKit
#endif

/// "Library and related features": flip-to-library. `SettingsView`'s "Other settings" section
/// links here and to `OtherSettingsView`.
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

    /// The flip opens the library's QR code, which needs a signed-in library account, so until one
    /// is the switch reads off and takes no input; the choice it holds waits for the sign-in.
    static func flipSwitch(_ enabled: Binding<Bool>, signedIn: Bool) -> Binding<Bool> {
        signedIn ? enabled : .constant(false)
    }

    /// Flip-to-Library is iPhone only (the iPad use case is unclear) and needs the motion sensor,
    /// so elsewhere this page would be empty and Settings leaves its row out.
    static var isAvailable: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone && FlipDetector.isSupported
        #else
        false
        #endif
    }
}
