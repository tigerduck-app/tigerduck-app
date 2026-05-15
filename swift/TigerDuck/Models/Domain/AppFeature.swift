import SwiftUI

enum AppFeature: String, CaseIterable, Identifiable, Codable {
    // Core pages
    case home
    case classTable
    case calendar
    case announcements

    // Academic
    case gpa
    case courseSelection
    case graduationRequirements

    // Library
    case library
    case discussionRoom
    case libraryLecture

    // Life
    case freeLunch
    case clubs
    case emptyClassroom
    case scholarship

    // Language
    case englishVocab

    // System
    case more
    case settings

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .home: String(localized: "feature_home")
        case .classTable: String(localized: "feature_class_table")
        case .calendar: String(localized: "feature_calendar")
        case .announcements: String(localized: "feature_announcements")
        case .library: String(localized: "feature_library")
        case .gpa: String(localized: "feature_score")
        case .courseSelection: String(localized: "feature_course_selection")
        case .graduationRequirements: String(localized: "feature_graduation_requirements")
        case .discussionRoom: String(localized: "feature_discussion_room")
        case .libraryLecture: String(localized: "feature_library_lecture")
        case .freeLunch: String(localized: "feature_free_lunch")
        case .clubs: String(localized: "feature_clubs")
        case .emptyClassroom: String(localized: "feature_empty_classroom")
        case .scholarship: String(localized: "feature_scholarship")
        case .englishVocab: String(localized: "feature_english_vocab")
        case .more: String(localized: "feature_more")
        case .settings: String(localized: "feature_settings")
        }
    }

    /// Tab-bar label. English locales otherwise truncate long labels (e.g.
    /// "Course selection") unevenly across tabs; the `_short` variants are
    /// hand-tuned in the localization repo. Settings has no short form
    /// because it never appears in the tab bar.
    var tabBarDisplayName: String {
        switch self {
        case .home: String(localized: "feature_home_short")
        case .classTable: String(localized: "feature_class_table_short")
        case .calendar: String(localized: "feature_calendar_short")
        case .announcements: String(localized: "feature_announcements_short")
        case .library: String(localized: "feature_library_short")
        case .gpa: String(localized: "feature_score_short")
        case .courseSelection: String(localized: "feature_course_selection_short")
        case .graduationRequirements: String(localized: "feature_graduation_requirements_short")
        case .discussionRoom: String(localized: "feature_discussion_room_short")
        case .libraryLecture: String(localized: "feature_library_lecture_short")
        case .freeLunch: String(localized: "feature_free_lunch_short")
        case .clubs: String(localized: "feature_clubs_short")
        case .emptyClassroom: String(localized: "feature_empty_classroom_short")
        case .scholarship: String(localized: "feature_scholarship_short")
        case .englishVocab: String(localized: "feature_english_vocab_short")
        case .more: String(localized: "feature_more_short")
        case .settings: displayName
        }
    }

    var iconName: String {
        switch self {
        case .home: "house.fill"
        case .classTable: "calendar.day.timeline.left"
        case .calendar: "calendar"
        case .announcements: "megaphone.fill"
        case .library: "books.vertical.fill"
        case .gpa: "chart.bar.fill"
        case .courseSelection: "pencil.and.list.clipboard"
        case .graduationRequirements: "graduationcap.fill"
        case .discussionRoom: "door.left.hand.open"
        case .libraryLecture: "mic.fill"
        case .freeLunch: "takeoutbag.and.cup.and.straw.fill"
        case .clubs: "person.3.fill"
        case .emptyClassroom: "building.2.fill"
        case .scholarship: "banknote.fill"
        case .englishVocab: "textformat.abc"
        case .more: "ellipsis.circle.fill"
        case .settings: "gearshape.fill"
        }
    }

    var isImplemented: Bool {
        switch self {
        case .home, .classTable, .calendar, .library, .announcements, .gpa:
            return true
        default:
            return false
        }
    }

    var category: FeatureCategory? {
        switch self {
        case .home, .classTable, .calendar: .page
        case .gpa, .courseSelection, .graduationRequirements: .academic
        case .library, .discussionRoom, .libraryLecture: .library
        case .announcements, .freeLunch, .clubs, .emptyClassroom, .scholarship: .life
        case .englishVocab: .language
        case .settings: .system
        default: nil
        }
    }

    /// Features that can be pinned to tab bar (positions 1-4)
    static let pinnableFeatures: [AppFeature] = [
        /// Temporary comments until feature is implemented.
        .home,
        .classTable,
        .calendar,
        .announcements,
        .library,
        .gpa,
//        .courseSelection,
//        .graduationRequirements,
//        .discussionRoom,
//        .libraryLecture,
//        .freeLunch,
//        .clubs,
//        .emptyClassroom,
//        .scholarship,
//        .englishVocab,
    ]

    /// Library-related features gated behind the library opt-in toggle
    static let libraryRelatedFeatures: Set<AppFeature> = [.library, .discussionRoom, .libraryLecture]

    static let defaultTabs: [AppFeature] = [
        .home, .classTable, .calendar,
    ]

    /// Features displayed in the "More" page, grouped by category
    static let moreFeatures: [AppFeature] = [
        /// Temporary comments until feature is implemented.
        .home,
        .classTable,
        .calendar,
        .announcements,
        .gpa,
//        .courseSelection,
//        .graduationRequirements,
        .library,
//        .discussionRoom,
//        .libraryLecture,
//        .freeLunch,
//        .clubs,
//        .emptyClassroom,
//        .scholarship,
//        .englishVocab,
    ]

    /// Features available as home screen widgets
    static let widgetFeatures: [AppFeature] = [
        /// Temporary comments until feature is implemented.
        .announcements,
//        .freeLunch,
//        .clubs,
//        .emptyClassroom,
        .gpa,
//        .scholarship,
//        .englishVocab,
    ]
}

enum FeatureCategory: String, CaseIterable, Identifiable {
    case page
    case academic
    case library
    case life
    case language
    case system

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .page: String(localized: "more_section_pages")
        case .academic: String(localized: "feature_category_academic")
        case .library: String(localized: "feature_category_library")
        case .life: String(localized: "feature_category_life")
        case .language: String(localized: "feature_category_language")
        case .system: String(localized: "feature_category_system")
        }
    }
}
