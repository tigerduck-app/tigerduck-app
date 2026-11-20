import SwiftUI

extension PageSettings {
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

struct AppDestination<Content: View>: View {
    @ViewBuilder let content: (AppEnvironment) -> Content
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        content(app)
    }
}
