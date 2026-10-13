import Foundation
import Observation

/// Observable "is the device's clock offset from Taipei?". Read
/// `TimezoneObserver.shared.isNonTaipei` in a view's dependency graph and
/// SwiftUI re-evaluates on `NSSystemTimeZoneDidChange` (travel, or automatic
/// time toggled) and when the debug clock moves, since DST can flip the answer.
///
/// Compares offsets at the current instant, not identifiers: `Asia/Hong_Kong`
/// shares Taipei's offset all year and must not trip the banner, while
/// `Europe/London` moves between BST and GMT.
@MainActor
@Observable
final class TimezoneObserver {
    static let shared = TimezoneObserver()

    private(set) var isNonTaipei: Bool

    private var clockToken: AppClock.ObserverToken?
    private var tzNotificationToken: NSObjectProtocol?

    private init() {
        isNonTaipei = Self.computeIsNonTaipei()

        // Hop to MainActor; the observer fires on whoever's thread called
        // `AppClock.setOverride`, which in practice is MainActor but the API
        // does not promise it.
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
            // The queue:.main delivery already puts us on MainActor, but the
            // closure crossing into a @MainActor class still needs the hop
            // to satisfy Swift 6 strict concurrency.
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
