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

    /// False for the graduates' leaving form (`SAGraduatesServ`), whose sign-in through ssoam's
    /// NetIQ page does not finish; the list shows it without opening it.
    var opens: Bool {
        url.host(percentEncoded: false)?.lowercased() != "stuinfosys.ntust.edu.tw"
            || url.pathComponents.dropFirst().first?.lowercased() != "sagraduatesserv"
    }

    /// Whether the site answers only on the school's network (TANet).
    var isCampusOnly: Bool {
        url.host(percentEncoded: false).map { Self.campusHosts.contains($0.lowercased()) } ?? false
    }

    private static let campusHosts: Set = ["software.ntust.edu.tw"]
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
