#if os(iOS)
import UIKit

/// Memoizes the *rendered* QR for the payload currently in flight.
///
/// `LibraryQRCache` deliberately stays a payload-and-countdown store: it is
/// compiled into the Watch app too, which renders its own pixels at its own
/// size, so putting a `UIImage` in there would drag UIKit across a boundary
/// that is better left clean.
///
/// Without this, every trip back to the Library tab pays for a full
/// CoreImage render of a code it already had — `LibraryView` holds its view
/// model in `@State`, so leaving the tab destroys it and the next
/// `startQRRefreshCycle()` sees `qrCodeImage == nil` and re-renders.
///
/// Single-entry by design: exactly one library code is live at a time, and
/// keeping older renders around would only risk handing the user pixels the
/// scanner will reject.
@MainActor
final class LibraryQRImageCache {
    static let shared = LibraryQRImageCache()

    private var cachedPayload: String?
    private var cachedImage: UIImage?

    init() {}

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
