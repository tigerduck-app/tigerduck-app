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
    /// User's selected visual style preset on the phone. The watch UI
    /// reads this to keep its course cards visually aligned with the
    /// main-app cards (TigerDuck = tinted; Apple = neutral + accent
    /// stripe). Defaults to `.default` for payloads from older phones
    /// that don't yet carry the field.
    public let visualPreset: VisualPreset
    /// JSON-encoded `ClockOverride` payload. Carried as an opaque string
    /// so this struct does not need to know about `ClockOverride`
    /// (`ClockOverride` is not in the `Shared/` target). The watch
    /// decodes it via `JSONDecoder().decode(ClockOverride.self, ...)`.
    /// `nil` when no debug override is active.
    public let clockOverrideJSON: String?

    public static let defaultAccentHex = "#FF8800"

    public init(
        version: Int = WatchWireFormat.version,
        courses: [WatchCourse],
        accentHex: String,
        syncedAtMs: Int64,
        loggedIn: Bool,
        languageTag: String?,
        visualPreset: VisualPreset = .default,
        clockOverrideJSON: String? = nil
    ) {
        self.version = version
        self.courses = courses
        self.accentHex = accentHex
        self.syncedAtMs = syncedAtMs
        self.loggedIn = loggedIn
        self.languageTag = languageTag
        self.visualPreset = visualPreset
        self.clockOverrideJSON = clockOverrideJSON
    }

    public var syncedAt: Date {
        Date(timeIntervalSince1970: TimeInterval(syncedAtMs) / 1000.0)
    }
}
