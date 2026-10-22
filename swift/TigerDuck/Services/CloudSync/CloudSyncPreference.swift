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
