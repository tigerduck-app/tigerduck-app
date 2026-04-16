import Foundation

/// Minimum payload the Live Activity extension needs to render.
/// Intentionally decoupled from SwiftData models so the extension target
/// never depends on `SDCourse` / `SDAssignment`.
nonisolated struct LiveActivitySnapshot: Codable, Equatable, Hashable, Sendable {
    let scenario: LiveActivityScenarioKind
    let title: String
    let subtitle: String
    let locationText: String?
    /// Target date for countdown timers (e.g. class end, assignment due).
    let countdownTarget: Date?
    /// 0.0 ... 1.0 for progress bars (nil when N/A).
    let progress: Double?
    /// Accent color as hex (matches AppState.accentColorHex format).
    let accentHex: Int
    let deepLink: URL?
    let privacyMode: Bool
    /// Stable id used for tie-breaks and `update` vs `end` decisions.
    let sourceId: String
}
