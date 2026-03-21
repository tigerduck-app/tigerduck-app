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
    case libraryQR
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
        case .home: "首頁"
        case .classTable: "課表"
        case .calendar: "行事曆"
        case .announcements: "公告"
        case .gpa: "GPA 查詢"
        case .courseSelection: "選課系統"
        case .graduationRequirements: "畢業門檻"
        case .libraryQR: "QR 入館"
        case .discussionRoom: "討論小間"
        case .libraryLecture: "圖書館講座"
        case .freeLunch: "免費便當"
        case .clubs: "社團活動"
        case .emptyClassroom: "空教室"
        case .scholarship: "獎學金"
        case .englishVocab: "英文單字測驗"
        case .more: "更多"
        case .settings: "設定"
        }
    }

    var iconName: String {
        switch self {
        case .home: "house.fill"
        case .classTable: "calendar.day.timeline.left"
        case .calendar: "calendar"
        case .announcements: "megaphone.fill"
        case .gpa: "chart.bar.fill"
        case .courseSelection: "pencil.and.list.clipboard"
        case .graduationRequirements: "graduationcap.fill"
        case .libraryQR: "qrcode"
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

    var category: FeatureCategory? {
        switch self {
        case .gpa, .courseSelection, .graduationRequirements: .academic
        case .libraryQR, .discussionRoom, .libraryLecture: .library
        case .freeLunch, .clubs, .emptyClassroom, .scholarship: .life
        case .englishVocab: .language
        case .settings: .system
        default: nil
        }
    }

    /// Features that can be pinned to tab bar (positions 1-4)
    static let pinnableFeatures: [AppFeature] = [
        .home, .classTable, .calendar, .announcements,
        .gpa, .courseSelection, .graduationRequirements,
        .libraryQR, .discussionRoom, .libraryLecture,
        .freeLunch, .clubs, .emptyClassroom, .scholarship,
        .englishVocab,
    ]

    static let defaultTabs: [AppFeature] = [
        .home, .classTable, .calendar, .announcements,
    ]

    /// Features displayed in the "More" page, grouped by category
    static let moreFeatures: [AppFeature] = [
        .gpa, .courseSelection, .graduationRequirements,
        .libraryQR, .discussionRoom, .libraryLecture,
        .freeLunch, .clubs, .emptyClassroom, .scholarship,
        .englishVocab,
    ]
}

enum FeatureCategory: String, CaseIterable, Identifiable {
    case academic
    case library
    case life
    case language
    case system

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .academic: "學業"
        case .library: "圖書館"
        case .life: "生活"
        case .language: "語言"
        case .system: "系統"
        }
    }
}
