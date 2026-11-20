import Foundation
import Observation

@MainActor
@Observable
final class AppClockState {
    static let shared = AppClockState()

    private(set) var version: UInt64 = AppClock.version()
    private var token: AppClock.ObserverToken?

    private init() {
        token = AppClock.observe { [weak self] v in
            Task { @MainActor [weak self] in
                self?.version = v
            }
        }
    }
}
