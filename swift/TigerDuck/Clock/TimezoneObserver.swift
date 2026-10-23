import Foundation
import Observation

@MainActor
@Observable
final class TimezoneObserver {
    static let shared = TimezoneObserver()

    private(set) var isNonTaipei: Bool

    private var clockToken: AppClock.ObserverToken?
    private var tzNotificationToken: NSObjectProtocol?

    private init() {
        isNonTaipei = Self.computeIsNonTaipei()

        clockToken = AppClock.observe { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recompute()
            }
        }

        tzNotificationToken = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                NSTimeZone.resetSystemTimeZone()
                self?.recompute()
            }
        }
    }

    private func recompute() {
        let next = Self.computeIsNonTaipei()
        if next != isNonTaipei {
            isNonTaipei = next
        }
    }

    private static func computeIsNonTaipei() -> Bool {
        let now = AppClock.now()
        let deviceOffset = TimeZone.current.secondsFromGMT(for: now)
        let taipeiOffset = AppConstants.taipeiTimeZone.secondsFromGMT(for: now)
        return deviceOffset != taipeiOffset
    }
}
