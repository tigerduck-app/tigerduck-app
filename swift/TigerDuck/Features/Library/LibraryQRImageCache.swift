#if os(iOS)
import UIKit

/// Memoizes the rendered QR for the payload currently in flight.
///
/// `LibraryQRCache` stays a payload-and-countdown store: the Watch app compiles
/// it too and renders its own pixels at its own size, so a `UIImage` there would
/// drag UIKit across that boundary. `LibraryView` keeps its view model in
/// `@State`, so leaving the tab destroys it, and without this cache the next
/// `startQRRefreshCycle()` would re-render a code it already had. One entry: one
/// code is live at a time, and older renders only risk pixels the scanner rejects.
@MainActor
final class LibraryQRImageCache {
    static let shared = LibraryQRImageCache()

    private var cachedPayload: String?
    private var cachedImage: UIImage?

    private var memoryWarningObserver: (any NSObjectProtocol)?

    init() {
        // A scale-10 QR is about half a megabyte of bitmap, and only the logout paths
        // call `clear()` otherwise, so one Library visit would hold it all session.
        // Dropping it under memory pressure costs one re-render on the next visit.
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { LibraryQRImageCache.shared.clear() }
        }
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    /// The rendered code for `payload`, or `nil` if what we hold is for a
    /// different one. The payload rotates every 30 s and a stale image is
    /// worse than a spinner — it scans as the wrong code.
    func image(for payload: String) -> UIImage? {
        cachedPayload == payload ? cachedImage : nil
    }

    func store(_ image: UIImage, for payload: String) {
        cachedPayload = payload
        cachedImage = image
    }

    func clear() {
        cachedPayload = nil
        cachedImage = nil
    }
}
#endif
