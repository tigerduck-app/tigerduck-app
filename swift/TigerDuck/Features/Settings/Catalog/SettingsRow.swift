import SwiftUI

nonisolated enum SettingsRow: String, CaseIterable, Identifiable {
    case schoolAccount, libraryAccount, mailAccount
    case accentColor, accentGradientOnDevices, visualPreset, colorTheme, tabBar
    case tigerSync
    case notificationPermissions
    case language
    case apiEndpoint, storage
    case version, checkForUpdates, serverStatus, whatsNew, website, aboutOthers
    case showFullDueDate, invertSlider, assignmentReminders, liveActivity
    case pinTodayCourses, showClassroom, outlineRequiredCourses, showAllPeriods, courseNameSize, classReminders
    case englishCourseNames, englishClassroomNames, mandarinClassroomNames, reassignCourseColors
    case bulletinPush
    case mailNotifications, mailDisplayName, mailStorage
    case flipToLibrary, librarySignOut
    case addressBar, websiteData
    case moodleNotifications, moodleStorage

    var id: Self { self }

    var label: String { String(localized: titleKey) }

    var titleKey: LocalizedStringResource {
        switch self {
        case .schoolAccount: "settings_account_ntust_system"
        case .libraryAccount: "settings_account_library_system"
        case .mailAccount: "school_mail_account_title"
        case .accentColor: "settings_accent_color"
        case .accentGradientOnDevices: "settings_accent_gradient_on_devices"
        case .visualPreset: "settings_visual_preset_label"
        case .colorTheme: "settings_color_theme"
        case .tabBar: "tab_editor_title"
        case .tigerSync: "cloud_sync_title"
        case .notificationPermissions: "notification_permission_settings_nav_title"
        case .language: "settings_language"
        case .apiEndpoint: "settings_api_endpoint"
        case .storage, .mailStorage, .websiteData, .moodleStorage: "settings_storage_title"
        case .version: "settings_version"
        case .checkForUpdates: "settings_check_for_updates"
        case .serverStatus: "settings_check_server_status"
        case .whatsNew: "settings_whats_new"
        case .website: "settings_official_website"
        case .aboutOthers: "settings_about_others"
        case .showFullDueDate: "settings_home_full_due_date"
        case .invertSlider: "settings_invert_slider_direction"
        case .assignmentReminders: "settings_assignment_due_reminder"
        case .liveActivity: "live_activity_settings_nav_title"
        case .pinTodayCourses: "settings_class_table_pin_today"
        case .showClassroom: "settings_class_table_show_classroom"
        case .outlineRequiredCourses: "settings_class_table_outline_required"
        case .showAllPeriods: "settings_class_table_all_periods"
        case .courseNameSize: "settings_font_size_title"
        case .classReminders: "settings_class_reminder"
        case .englishCourseNames: "settings_use_english_course_abbreviation"
        case .englishClassroomNames: "settings_use_english_classroom_abbreviation"
        case .mandarinClassroomNames: "settings_classroom_mandarin_display"
        case .reassignCourseColors: "settings_reset_course_colors"
        case .bulletinPush: "bulletin_push_settings_header"
        case .mailNotifications: "school_mail_settings_notifications"
        case .mailDisplayName: "school_mail_settings_display_name"
        case .flipToLibrary: "settings_library_flip_to_show_qr"
        case .librarySignOut: "settings_library_sign_out"
        case .addressBar: "browser_address_bar"
        case .moodleNotifications: "moodle_notification_settings_title"
        }
    }
}
