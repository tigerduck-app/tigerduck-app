#if os(iOS)
import CoreImage.CIFilterBuiltins
import UIKit

/// Rasterises a library QR payload.
///
/// Extracted from `LibraryViewModel` so every path that needs a code
/// rasterises through exactly the same parameters — two renderers would
/// eventually disagree on scale or correction level and produce codes that
/// scan differently depending on which one made them.
enum LibraryQRRenderer {

    /// One context for the app's lifetime — creating one per QR compiles
    /// Core Image's Metal pipeline every 30 s.
    // Plain `nonisolated`, not `nonisolated(unsafe)`: `CIContext` is `Sendable` in
    // the current SDK. The annotation is still needed because the module defaults
    // to MainActor isolation and `image(from:)` runs off it.
    nonisolated private static let ciContext = CIContext()

    nonisolated static func image(from string: String) -> UIImage? {
        // Plain SDR render. `HDRQRCodeImage` applies the HDR brightness at draw time
        // in a Metal shader; doing it here in CoreImage is unreliable, since the filter
        // chain clamps and SwiftUI does not tag synthetic UIImages as HDR.
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
