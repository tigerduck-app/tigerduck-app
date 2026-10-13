#if os(macOS)
import SwiftUI

/// Mac-native Settings window (⌘,).
///
/// Covers the `AppState` settings that mean something on a Mac: appearance (accent and
/// course palette), language, display and abbreviation toggles, link opening, the API
/// endpoint override, TigerSync, and the Mac-only sidebar pins and their order. Push, Live
/// Activity and library settings are left out as iOS-only or in `AppFeature.macHiddenFeatures`.
///
/// Debug builds add a Developer tab so QA can scrub fake time on the Mac as on the iPhone.
struct MacSettingsScene: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        TabView {
            MacGeneralSettingsView()
                .tabItem { Label(String(localized: "desktop_settings_tab_general"), systemImage: "gearshape") }
            MacAppearanceSettingsView()
                .tabItem { Label(String(localized: "desktop_settings_tab_appearance"), systemImage: "paintpalette") }
            MacSidebarSettingsView()
                .tabItem { Label(String(localized: "desktop_settings_tab_sidebar"), systemImage: "sidebar.left") }
            MacAccountSettingsView()
                .tabItem { Label(String(localized: "settings_section_account"), systemImage: "person.circle") }
            MacTigerSyncSettingsView()
                .tabItem { Label(String(localized: "cloud_sync_title"), systemImage: "arrow.triangle.2.circlepath.icloud") }
            MacOtherSettingsView()
                .tabItem { Label(String(localized: "settings_section_other_settings"), systemImage: "ellipsis.circle") }
            #if DEBUG
            MacDeveloperSettingsView()
                .tabItem { Label("Developer", systemImage: "hammer") }
            #endif
            MacAboutSettingsView()
                .tabItem { Label(String(localized: "settings_section_about"), systemImage: "info.circle") }
        }
        .frame(width: 580, height: 480)
        // Separate scene from MacRootView, so the theme tint has to be
        // applied here too or `.tint`-styled icons fall back to the system accent.
        .tint(appState.accentColor)
    }
}
#endif
