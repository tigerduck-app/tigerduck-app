#if os(macOS)
import SwiftUI

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
        .tint(appState.accentColor)
    }
}
#endif
