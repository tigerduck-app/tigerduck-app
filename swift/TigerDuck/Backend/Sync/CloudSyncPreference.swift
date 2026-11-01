import Defaults
import Foundation
import Observation

@MainActor
@Observable
final class CloudSyncPreference {
    private let cloudSyncEnabled: Defaults.Key<Bool>
    @ObservationIgnored private var handler: ((Bool) -> Void)?
    @ObservationIgnored private var observation: (any Defaults.Observation)?

    init(key cloudSyncEnabled: Defaults.Key<Bool> = .cloudSyncEnabled) {
        self.cloudSyncEnabled = cloudSyncEnabled
        observation = Defaults.observe(cloudSyncEnabled, options: []) { [weak self] change in
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
        access(keyPath: \.isEnabled)
        return Defaults[cloudSyncEnabled]
    }

    func setEnabled(_ enabled: Bool, for signIn: SignIn) {
        guard signIn.isCurrent else { return }
        Defaults[cloudSyncEnabled] = enabled
    }

    /// The sign-out turns TigerSync off after its sign-in has ended.
    func turnOff() {
        Defaults[cloudSyncEnabled] = false
    }

    func onChange(_ handler: @escaping (Bool) -> Void) {
        self.handler = handler
    }

    private func didChange(to enabled: Bool) {
        withMutation(keyPath: \.isEnabled) {}
        handler?(enabled)
    }
}
