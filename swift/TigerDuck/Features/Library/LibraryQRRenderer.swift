#if os(iOS)
import CoreImage.CIFilterBuiltins
import UIKit

/// Rasterises a library QR payload.
///
/// Extracted from `LibraryViewModel` so the speculative warm path in
/// ``LibraryQRPrewarmer`` renders through exactly the same code — two
/// renderers would eventually disagree on scale or correction level and
/// produce a code that scans differently depending on how it was warmed.
enum LibraryQRRenderer {

    /// One context for the app's lifetime — creating one per QR compiles
    /// Core Image's Metal pipeline every 30 s.
    // `nonisolated` (not `nonisolated(unsafe)`) — `CIContext` is `Sendable`
    // in the current SDK, so the unchecked escape hatch is no longer needed.
    // The annotation itself still is: the module defaults to MainActor
    // isolation, and `image(from:)` runs off it.
    nonisolated private static let ciContext = CIContext()

    nonisolated static func image(from string: String) -> UIImage? {
        // Plain SDR black/white render. HDR brightness is applied at draw
        // time by `HDRQRCodeImage` via a Metal shader against an EDR-enabled
        // CAMetalLayer — doing it here through CoreImage's filter chain
        // proved unreliable (false-color clamping + SwiftUI not tagging
        // synthetic UIImages as HDR).
        let context = ciContext
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let ciImage = filter.outputImage else { return nil }
        let scale: CGFloat = 10
        let transformed = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
#endif
