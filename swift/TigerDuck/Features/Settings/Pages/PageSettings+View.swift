import SwiftUI

extension PageSettings {
    /// The page's settings, the same from Settings and from the page itself, which pushes it
    /// or presents it in a `NavigationStack`.
    var view: some View {
        content
            .navigationTitle(String(localized: titleKey))
            .inlineNavigationTitle()
            .toastHost()
            .settingsEnvironment()
    }

    @ViewBuilder
    private var content: some View {
        switch self {
        case .home: HomePageSettingsView()
        case .classTable: ClassTablePageSettingsView()
        case .bulletins: BulletinsPageSettingsView()
        case .mail: MailSettingsView()
        case .library: LibrarySettingsView()
        case .browser: BrowserPageSettingsView()
        case .moodle: MoodlePageSettingsView()
        }
    }
}

/// A destination built from the app only once it is shown, so a page that links to it can be
/// shown without one.
struct AppDestination<Content: View>: View {
    @ViewBuilder let content: (AppEnvironment) -> Content
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        content(app)
    }
}
