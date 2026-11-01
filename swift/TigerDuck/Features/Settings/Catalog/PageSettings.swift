import SwiftUI

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

    func isShown(in state: SettingsState) -> Bool {
        rows.contains { $0.isShown(in: state) }
    }
}
