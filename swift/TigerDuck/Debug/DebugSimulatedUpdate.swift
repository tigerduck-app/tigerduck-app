#if DEBUG
import Foundation

enum DebugSimulatedUpdate {
    private static let key = "debug.simulateUpdateOnNextLaunch"

    static func arm() {
        AppUserDefaults.standard.set(true, forKey: key)
    }

    static var isArmed: Bool {
        AppUserDefaults.standard.bool(forKey: key)
    }

    static func consume() -> Bool {
        let armed = AppUserDefaults.standard.bool(forKey: key)
        if armed {
            AppUserDefaults.standard.removeObject(forKey: key)
        }
        return armed
    }
}
#endif
