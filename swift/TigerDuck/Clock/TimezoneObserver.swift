import Foundation
import Observation

/// Observable signal for "is the device's wall clock currently offset from
/// Taipei?". Read `TimezoneObserver.shared.isNonTaipei` somewhere in a view's
/// dependency graph and SwiftUI re-evaluates when:
///   - The system posts `NSSystemTimeZoneDidChange` (traveler crosses a
///     timezone boundary, or settings toggles automatic time).
///   - The debug clock flips — DST status changes across the year, so the
///     same device can be in/out of Taipei offset depending on "now".
///
/// Compares the offset (not the identifier) at the current instant: a device
/// set to `Asia/Hong_Kong` shares Taipei's offset year-round and should not
/// trip the banner; a device set to `Europe/London` switches between BST and
/// GMT, so DST flips matter.
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
