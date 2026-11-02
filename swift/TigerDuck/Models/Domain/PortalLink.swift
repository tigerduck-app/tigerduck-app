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

    init(category: PortalCategory, name: String, url: URL) {
        self.category = category
        self.name = name
        self.url = Self.opening(url)
    }

    /// A saved list holds the addresses of the day it was fetched; they open as a fresh list would.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            category: container.decode(PortalCategory.self, forKey: .category),
            name: container.decode(String.self, forKey: .name),
            url: container.decode(URL.self, forKey: .url)
        )
    }

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

    private static let campusHosts: Set = ["software.ntust.edu.tw", "ccdoc.ntust.edu.tw"]

    /// The portal still links the research ethics course at `ae.ntust.edu.tw`, whose certificate
    /// covers only `*.cge.ntust.edu.tw`; the course is served at `ae.cge.ntust.edu.tw`.
    private static let movedHosts = ["ae.ntust.edu.tw": "ae.cge.ntust.edu.tw"]

    /// The portal links the computer center's page about campus software, in each language; the
    /// app opens the software download site's sign-in, which that page points to.
    private static let replacedPages = Set(["/p/412-1050-8352.php", "/p/412-1050-8701.php"])
    private static let campusSoftware = URL.knownGood("https://software.ntust.edu.tw/websoftware/login.aspx")

    private static func opening(_ url: URL) -> URL {
        if url.host(percentEncoded: false)?.lowercased() == "www.cc.ntust.edu.tw", replacedPages.contains(url.path(percentEncoded: true)) {
            return campusSoftware
        }
        guard let host = url.host(percentEncoded: false)?.lowercased(), let movedHost = movedHosts[host],
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.host = movedHost
        return components.url ?? url
    }
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
