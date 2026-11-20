import Foundation

nonisolated enum SchoolMailAvailability {
    static var isEnabled: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }
}
