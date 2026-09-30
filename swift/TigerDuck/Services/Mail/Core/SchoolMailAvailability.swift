import Foundation

/// Whether the School Mail feature is shown at all: always on iOS, never on macOS.
nonisolated enum SchoolMailAvailability {
    static var isEnabled: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }
}
