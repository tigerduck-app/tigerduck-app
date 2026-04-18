import Foundation

/// Minimum payload the Live Activity extension needs to render.
/// Intentionally decoupled from SwiftData models so the extension target
/// never depends on `SDCourse` / `SDAssignment`.
nonisolated struct LiveActivitySnapshot: Codable, Equatable, Hashable, Sendable {
    let scenario: LiveActivityScenarioKind
    let title: String
    let subtitle: String
    let locationText: String?
    let instructor: String?
    /// Target date for countdown timers (e.g. class end, assignment due).
    let countdownTarget: Date?
    /// Start date for progress bars. When paired with `countdownTarget` the
    /// widget renders `ProgressView(timerInterval:)`, which the system animates
    /// on-device for free. `nil` hides the bar. Must satisfy
    /// `progressStart < countdownTarget` when set.
    let progressStart: Date?
    /// Accent color as hex (matches AppState.accentColorHex format).
    let accentHex: Int
    let deepLink: URL?
    /// Stable id used for tie-breaks and `update` vs `end` decisions.
    let sourceId: String
}
