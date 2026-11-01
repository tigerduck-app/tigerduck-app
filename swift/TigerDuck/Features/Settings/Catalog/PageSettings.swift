import SwiftUI

/// The pages that have settings of their own, in the order Settings lists them.
nonisolated enum PageSettings: CaseIterable, Identifiable {
    case home, classTable, bulletins, mail, library, browser, moodle

    var id: Self { self }

    var titleKey: LocalizedStringResource {
        switch self {
        case .home: "feature_home"
        case .classTable: "feature_class_table"
        case .bulletins: "feature_announcements"
        case .mail: "feature_school_mail"
        case .library: "feature_library"
        case .browser: "settings_page_browser"
        case .moodle: "settings_page_moodle"
        }
    }

    var rows: [SettingsRow] {
        SettingsRow.allCases.filter { $0.place == .page(self) }
    }

    /// A page with no row to show, such as the library on an iPad while signed out, is not listed.
    func isShown(in state: SettingsState) -> Bool {
        rows.contains { $0.isShown(in: state) }
    }
}
