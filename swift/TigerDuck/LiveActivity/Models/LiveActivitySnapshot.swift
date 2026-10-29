import Foundation

nonisolated struct LiveActivitySnapshot: Codable, Equatable, Hashable, Sendable {
    let scenario: LiveActivityScenarioKind
    let title: String
    let subtitle: String
    let locationText: String?
    let instructor: String?
    let countdownTarget: Date?
    /// Start date for progress bars. When paired with `countdownTarget` the
    /// widget renders `ProgressView(timerInterval:)`, which the system animates
    /// on-device for free. `nil` hides the bar. Must satisfy
    let progressStart: Date?
    let accentHex: Int
    let deepLink: URL?
    let sourceId: String
    /// True when the school changed the room or the time that day. Nil is left out of the JSON,
    /// so an unchanged class encodes as before and the server passes the keys on untouched.
    var roomChanged: Bool? = nil
    var timeChanged: Bool? = nil

    /// activity and the follow-up inClass activity are distinct as far as
    /// ActivityKit is concerned — PTS cannot update an existing activity, so
    /// sharing the id would make iOS silently drop the second push. The same
    /// format MUST be used on the server (`{scenario}::{source_id}`).
    var composedActivityId: String {
        "\(scenario.rawValue)::\(sourceId)"
    }
}
