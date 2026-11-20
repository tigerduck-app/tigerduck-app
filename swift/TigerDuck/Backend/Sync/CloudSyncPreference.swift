import Defaults
import Foundation
import Observation

@MainActor
@Observable
final class CloudSyncPreference {
    private let cloudSyncEnabled: AccountKey<Bool>
    @ObservationIgnored private var handler: ((Bool) -> Void)?
    @ObservationIgnored private var observation: (any Defaults.Observation)?

    init(key cloudSyncEnabled: AccountKey<Bool> = .cloudSyncEnabled) {
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

    /// The sign-out turns TigerSync off for the sign-in that follows it.
    func setEnabled(_ enabled: Bool, for signIn: SignIn) {
        Defaults[cloudSyncEnabled, for: signIn] = enabled && !signIn.isDemo
    }

    static func turnOffForDemo(_ signIn: SignIn, key: AccountKey<Bool> = .cloudSyncEnabled) {
        guard signIn.isDemo else { return }
        Defaults[key, for: signIn] = false
    }

    func onChange(_ handler: @escaping (Bool) -> Void) {
        self.handler = handler
    }

    private func didChange(to enabled: Bool) {
        withMutation(keyPath: \.isEnabled) {}
        handler?(enabled)
    }
}
