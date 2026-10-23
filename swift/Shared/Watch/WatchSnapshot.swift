import Foundation

public nonisolated struct WatchSnapshot: Codable, Equatable, Sendable {
    public let version: Int
    public let courses: [WatchCourse]
    public let accentHex: String
    public let syncedAtMs: Int64
    public let loggedIn: Bool
    public let languageTag: String?
    public let visualPreset: VisualPreset
    public let clockOverrideJSON: String?
    public let quietDays: Set<String>

    public static let defaultAccentHex = "#FF8800"

    public init(
        version: Int = WatchWireFormat.version,
        courses: [WatchCourse],
        accentHex: String,
        syncedAtMs: Int64,
        loggedIn: Bool,
        languageTag: String?,
        visualPreset: VisualPreset = .default,
        clockOverrideJSON: String? = nil,
        quietDays: Set<String> = []
    ) {
        self.version = version
        self.courses = courses
        self.accentHex = accentHex
        self.syncedAtMs = syncedAtMs
        self.loggedIn = loggedIn
        self.languageTag = languageTag
        self.visualPreset = visualPreset
        self.clockOverrideJSON = clockOverrideJSON
        self.quietDays = quietDays
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decode(Int.self, forKey: .version)
        self.courses = try c.decode([WatchCourse].self, forKey: .courses)
        self.accentHex = try c.decode(String.self, forKey: .accentHex)
        self.syncedAtMs = try c.decode(Int64.self, forKey: .syncedAtMs)
        self.loggedIn = try c.decode(Bool.self, forKey: .loggedIn)
        self.languageTag = try c.decodeIfPresent(String.self, forKey: .languageTag)
        self.visualPreset = try c.decodeIfPresent(VisualPreset.self, forKey: .visualPreset) ?? .default
        self.clockOverrideJSON = try c.decodeIfPresent(String.self, forKey: .clockOverrideJSON)
        self.quietDays = try c.decodeIfPresent(Set<String>.self, forKey: .quietDays) ?? []
    }

    public var syncedAt: Date {
        Date(timeIntervalSince1970: TimeInterval(syncedAtMs) / 1000.0)
    }
}
