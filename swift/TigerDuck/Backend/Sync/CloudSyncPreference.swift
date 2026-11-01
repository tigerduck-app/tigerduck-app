import Defaults
import Foundation
import Observation

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

    func onChange(_ handler: @escaping (Bool) -> Void) {
        self.handler = handler
    }

    private func didChange(to enabled: Bool) {
        withMutation(keyPath: \.isEnabled) {}
        handler?(enabled)
    }
}
