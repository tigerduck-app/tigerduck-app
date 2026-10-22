#if os(iOS)
import CoreImage.CIFilterBuiltins
import UIKit

enum LibraryQRRenderer {

    nonisolated private static let ciContext = CIContext()

    nonisolated static func image(from string: String) -> UIImage? {
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
