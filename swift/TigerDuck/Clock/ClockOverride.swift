import Foundation

/// Snapshot of a debug-time override. `savedAtReal` is the real (`Date()`)
/// instant at which this override was saved; it anchors ticking-mode math
/// so a value persisted in App Group `UserDefaults` and applied later still
/// computes the right elapsed delta.
struct ClockOverride: Codable, Equatable, Sendable {
    let instant: Date
    let frozen: Bool
    let savedAtReal: Date
}
