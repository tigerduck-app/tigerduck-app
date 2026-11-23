#if DEBUG
import Foundation
import WidgetKit
import os.log

@MainActor
final class DebugClockController {

    static let shared = DebugClockController()

    static let didChangeNotification = Notification.Name("AppClockDidChange")

    /// The launch argument `-debug.clock.shareWithExtensions YES` that tools/app_store_screenshots.py passes.
    static let shareWithExtensionsKey = "debug.clock.shareWithExtensions"

    private let store = DebugClockStore()
    private let log = Logger(subsystem: "org.ntust.app.TigerDuck", category: "DebugClock")

    private init() {}

    func bootstrap() {
        guard let persisted = store.load() else { return }
        // A `-debug.clock.override` launch argument reaches only this process; saved, it also
        // reaches the widget and Live Activity extensions, and outlives the argument.
        if AppUserDefaults.standard.bool(forKey: Self.shareWithExtensionsKey) { store.save(persisted) }
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
