import Defaults
import Foundation
import Observation

/// The Sync course information preference. Its only copy is `Defaults[.cloudSyncEnabled]`;
/// `AppState.cloudSyncEnabled` forwards here. Onboarding, the `@Default` switch in TigerSync
/// settings, the Mac toggles (through `AppState`) and sign-out all write it, and a change's
/// effects (Live Activity, the push schedule, `CloudSyncCoordinator`) must follow whichever
/// wrote it. So `isEnabled` reads it every time, and each change in this process reaches the
/// handler once. `Defaults.observe` is KVO and calls back inside the write, so effects start
/// before the writer's next line. Writing the value already stored, its default included,
/// reports nothing.
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
