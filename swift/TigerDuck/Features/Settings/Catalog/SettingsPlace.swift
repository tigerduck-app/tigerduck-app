import SwiftUI

/// Where a row sits: a section of the Settings root, or a page's settings view.
nonisolated enum SettingsPlace: Hashable {
    case section(SettingsSection)
    case page(PageSettings)

    /// The section or page name, nil for the root section that has no header.
    var titleKey: LocalizedStringResource? {
        switch self {
        case .section(let section): section.titleKey
        case .page(let page): page.titleKey
        }
    }
}

/// The Settings root's sections other than the page rows, in their order on screen.
nonisolated enum SettingsSection: CaseIterable {
    case account, appearance, tigerSync, notificationPermissions, language, other, about

    var titleKey: LocalizedStringResource? {
        switch self {
        case .account: "settings_section_account"
        case .appearance: "settings_section_appearance"
        case .tigerSync: "cloud_sync_title"
        case .notificationPermissions: nil
        case .language: "feature_category_language"
        case .other: "settings_section_other_settings"
        case .about: "settings_section_about"
        }
    }
}

/// A condition that has to hold before a row can be used. A closed gate leaves the row on
/// screen, looking disabled, and a tap shows the reason.
nonisolated enum SettingsGate {
    case tigerSync, schoolSignIn, mailSignIn, librarySignIn

    var reasonKey: LocalizedStringResource {
        switch self {
        case .tigerSync: "settings_gate_tigersync"
        case .schoolSignIn: "settings_gate_school_sign_in"
        case .mailSignIn: "settings_gate_mail_sign_in"
        case .librarySignIn: "settings_gate_library_sign_in"
        }
    }

    func isOpen(in state: SettingsState) -> Bool {
        switch self {
        case .tigerSync: state.isCloudSyncOn
        case .schoolSignIn: state.school.isSignedIn
        case .mailSignIn: state.mail.isSignedIn
        case .librarySignIn: state.library.isSignedIn
        }
    }
}

nonisolated extension SettingsRow {
    var place: SettingsPlace {
        switch self {
        case .schoolAccount, .libraryAccount, .mailAccount: .section(.account)
        case .accentColor, .visualPreset, .colorTheme, .tabBar: .section(.appearance)
        case .tigerSync: .section(.tigerSync)
        case .notificationPermissions: .section(.notificationPermissions)
        case .language: .section(.language)
        case .apiEndpoint, .storage: .section(.other)
        case .version, .checkForUpdates, .serverStatus, .whatsNew, .website, .aboutOthers: .section(.about)
        case .showFullDueDate, .invertSlider, .assignmentReminders, .liveActivity: .page(.home)
        case .pinTodayCourses, .showClassroom, .outlineRequiredCourses, .showAllPeriods, .courseNameSize,
             .classReminders, .englishCourseNames, .englishClassroomNames, .mandarinClassroomNames,
             .reassignCourseColors: .page(.classTable)
        case .bulletinPush: .page(.bulletins)
        case .mailNotifications, .mailDisplayName, .mailStorage: .page(.mail)
        case .flipToLibrary, .librarySignOut: .page(.library)
        case .addressBar, .websiteData: .page(.browser)
        case .moodleNotifications, .moodleStorage: .page(.moodle)
        }
    }

    var gate: SettingsGate? {
        switch self {
        case .assignmentReminders, .liveActivity, .classReminders: .tigerSync
        case .bulletinPush, .moodleNotifications: .schoolSignIn
        case .mailNotifications, .mailDisplayName: .mailSignIn
        case .flipToLibrary: .librarySignIn
        default: nil
        }
    }

    /// Whether the row is on screen at all; search lists only these.
    func isShown(in state: SettingsState) -> Bool {
        switch self {
        case .mailAccount, .mailNotifications, .mailDisplayName, .mailStorage: state.hasSchoolMail
        case .whatsNew: state.hasWhatsNew
        case .englishCourseNames, .englishClassroomNames: !state.isChineseUI
        case .mandarinClassroomNames: !state.isChineseUI && state.usesEnglishClassroomNames
        case .flipToLibrary: state.hasFlipToLibrary
        case .librarySignOut: state.library.isSignedIn
        default: true
        }
    }

    /// The reason the row cannot be used now, or nil when it can.
    func closedReason(in state: SettingsState) -> LocalizedStringResource? {
        guard let gate, !gate.isOpen(in: state) else { return nil }
        return gate.reasonKey
    }
}
