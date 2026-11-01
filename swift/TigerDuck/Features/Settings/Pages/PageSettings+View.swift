import SwiftUI

extension PageSettings {
    /// The page's settings, the same from Settings and from the page itself, which pushes it
    /// or presents it in a `NavigationStack`.
    var view: some View {
        content
            .navigationTitle(String(localized: titleKey))
            .inlineNavigationTitle()
            .modifier(LeavesWhenEmpty(page: self))
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

/// Goes back once the page has no row left, as after a sign-out on a page whose other rows the
/// device lacks.
private struct LeavesWhenEmpty: ViewModifier {
    let page: PageSettings
    @Environment(\.settingsState) private var state
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.onChange(of: page.isShown(in: state)) { _, isShown in
            if !isShown { dismiss() }
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
