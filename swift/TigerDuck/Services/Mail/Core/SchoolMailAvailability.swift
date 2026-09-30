import Foundation

/// Whether the School Mail feature is shown at all.
///
/// Built but hidden until the NTUST computer center gives written consent (design doc
/// §1.6 / §12.5): DEBUG builds show it; Release builds only once `releaseEnabled` is
/// flipped. Never on macOS.
nonisolated enum SchoolMailAvailability {
    /// Flip to `true` in the release that ships after the written consent arrives.
    static let releaseEnabled = false

    static var isEnabled: Bool {
        #if os(iOS)
        #if DEBUG
        return true
        #else
        return releaseEnabled
        #endif
        #else
        return false
        #endif
    }
}
