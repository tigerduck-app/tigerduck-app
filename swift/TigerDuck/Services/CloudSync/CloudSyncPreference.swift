import Defaults
import Foundation
import Observation

/// 同步課程資訊, read and written through its only copy:
/// `Defaults[.cloudSyncEnabled]`.
///
/// Several writers set that preference directly — onboarding, the
/// `@Default`-bound switch in TigerSync settings, the Mac toggles through
/// `AppState`, sign-out — and what a change sets off (Live Activity ending or
/// resuming, the push schedule, `CloudSyncCoordinator` following) has to
/// happen whichever of them made it. So there is no second copy to keep in
/// step: `isEnabled` reads the preference every time, and every change to it
/// in this process reaches the handler once. `AppState.cloudSyncEnabled`
/// forwards here.
///
/// Observed synchronously: `Defaults.observe` is KVO, which calls back inside
/// the write, so a change's side effects are under way before the writer's
/// next line runs. UserDefaults reports only writes that change the value, so
/// writing the value already there — its default included — reports nothing.
@MainActor
@Observable
final class CloudSyncPreference {
    private let key: Defaults.Key<Bool>
    @ObservationIgnored private var handler: ((Bool) -> Void)?
    @ObservationIgnored private var observation: (any Defaults.Observation)?

    init(key: Defaults.Key<Bool> = .cloudSyncEnabled) {
        self.key = key
        observation = Defaults.observe(key, options: []) { [weak self] change in
            let enabled = change.newValue
            // KVO calls back on the writer's thread. Every writer is on the
            // main actor; one that is not has the change delivered there
            // instead of trapping.
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.didChange(to: enabled) }
            } else {
                Task { @MainActor in self?.didChange(to: enabled) }
            }
        }
    }

    var isEnabled: Bool {
        get {
            access(keyPath: \.isEnabled)
            return Defaults[key]
        }
        set { Defaults[key] = newValue }
    }

    /// Installs the handler for every change. `AppState` does, at the end of
    /// its `init`.
    func onChange(_ handler: @escaping (Bool) -> Void) {
        self.handler = handler
    }

    private func didChange(to enabled: Bool) {
        withMutation(keyPath: \.isEnabled) {}
        handler?(enabled)
    }
}
