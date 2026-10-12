import Foundation

/// Snapshot of a debug-time override. `savedAtReal` is the real (`Date()`)
/// instant at which this override was saved; it anchors ticking-mode math
/// so a value persisted in App Group `UserDefaults` and applied later still
/// computes the right elapsed delta.
nonisolated struct ClockOverride: Codable, Equatable, Sendable {
    let instant: Date
    let frozen: Bool
    let savedAtReal: Date

    /// Reads `WatchSnapshot.clockOverrideJSON`, the form the phone sends the Watch; nil when
    /// there is none or it does not decode.
    static func decode(snapshotJSON json: String?) -> ClockOverride? {
        guard let data = json?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ClockOverride.self, from: data)
    }
}
