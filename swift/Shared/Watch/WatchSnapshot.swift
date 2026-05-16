import Foundation

/// Decoded watch-side view of one applicationContext push. Lives in the
/// shared App Group file so the widget can read it without WC.
public struct WatchSnapshot: Codable, Equatable, Sendable {
    public let version: Int
    public let courses: [WatchCourse]
    public let accentHex: String
    public let syncedAtMs: Int64
    public let loggedIn: Bool
    public let languageTag: String?

    public static let defaultAccentHex = "#FF8800"

    public init(
        version: Int = WatchWireFormat.version,
        courses: [WatchCourse],
        accentHex: String,
        syncedAtMs: Int64,
        loggedIn: Bool,
        languageTag: String?
    ) {
        self.version = version
        self.courses = courses
        self.accentHex = accentHex
        self.syncedAtMs = syncedAtMs
        self.loggedIn = loggedIn
        self.languageTag = languageTag
    }

    public var syncedAt: Date {
        Date(timeIntervalSince1970: TimeInterval(syncedAtMs) / 1000.0)
    }
}
