import Foundation

/// The six groups of the school's student portal, named by the id of the block that holds each
/// group's links on `i.ntust.edu.tw/student`.
nonisolated enum PortalCategory: String, CaseIterable, Codable, Sendable {
    case curriculum = "service-1"
    case personalInfo = "service-2"
    case campusLife = "service-3"
    case financialSupport = "service-4"
    case activities = "service-5"
    case resources = "service-6"

    var titleKey: LocalizedStringResource {
        switch self {
        case .curriculum: "information_system_category_curriculum"
        case .personalInfo: "information_system_category_personal_info"
        case .campusLife: "information_system_category_campus_life"
        case .financialSupport: "information_system_category_financial_support"
        case .activities: "information_system_category_activities"
        case .resources: "information_system_category_resources"
        }
    }
}

nonisolated struct PortalLink: Codable, Hashable, Identifiable, Sendable {
    let category: PortalCategory
    let name: String
    let url: URL

    var id: Self { self }
}

/// The portal has a Chinese page and a separate English one.
nonisolated enum PortalLanguage: String, Codable, Sendable {
    case zh, en

    init(appLanguage: String) {
        self = LanguageManager.isCourseApiEnglish(appLanguage: appLanguage) ? .en : .zh
    }

    var pageURL: URL {
        switch self {
        case .zh: URL.knownGood("https://i.ntust.edu.tw/student")
        case .en: URL.knownGood("https://i.ntust.edu.tw/EN/student")
        }
    }
}
