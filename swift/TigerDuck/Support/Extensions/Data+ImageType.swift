import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated extension Data {
    /// The image format ImageIO finds in the bytes, whatever type they were sent as.
    var imageType: UTType? {
        guard let source = CGImageSourceCreateWithData(self as CFData, nil) else { return nil }
        return CGImageSourceGetType(source).flatMap { UTType($0 as String) }
    }
}
