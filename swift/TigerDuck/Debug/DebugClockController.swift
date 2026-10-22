#if DEBUG
import Foundation
import WidgetKit
import os.log

@MainActor
final class DebugClockController {

    static let shared = DebugClockController()

    static let didChangeNotification = Notification.Name("AppClockDidChange")

    private let store = DebugClockStore()
    private let log = Logger(subsystem: "org.ntust.app.TigerDuck", category: "DebugClock")

    private init() {}

    func bootstrap() {
        guard let persisted = store.load() else { return }
        AppClock.setOverride(persisted)
        log.debug("Bootstrapped clock override: frozen=\(persisted.frozen, privacy: .public)")
    }

    func setOverride(_ override: ClockOverride?) {
        if let override {
            store.save(override)
        } else {
            store.clear()
        }
        AppClock.setOverride(override)

        WidgetCenter.shared.reloadAllTimelines()

        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        log.debug("setOverride applied; active=\(override != nil, privacy: .public)")
    }

    func currentOverride() -> ClockOverride? {
        AppClock.currentOverride()
    }
}
#endif
