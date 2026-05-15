import Foundation

struct WidgetSnapshot: Codable, Equatable, Hashable, Sendable {
    let version: Int
    let generatedAt: Date
    let isLoggedIn: Bool
    let accentColorHex: UInt32
    let courses: [SnapshotCourse]
    let periodTimes: [String: PeriodTime]
    let periodOrder: [String]
    let activeWeekdays: [Int]
    let activePeriodIds: [String]

    static let currentVersion = 1
    static let storeKey = "Widget-snapshot-v1"
    static let appGroupIdentifier = "group.org.ntust.app.TigerDuck1"
}

struct SnapshotCourse: Codable, Equatable, Hashable, Sendable {
    let courseNo: String
    let displayName: String
    let classroom: String
    let schedule: [Int: [String]]
    let colorHex: UInt32
}

struct PeriodTime: Codable, Equatable, Hashable, Sendable {
    let start: String   // "HH:mm"
    let end: String     // "HH:mm"
}
