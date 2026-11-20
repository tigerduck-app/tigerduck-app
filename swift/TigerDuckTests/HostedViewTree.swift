#if canImport(UIKit)
import UIKit

extension UIView {
    func descendants<View: UIView>(ofType type: View.Type) -> [View] {
        subviews.flatMap { [$0 as? View].compactMap { $0 } + $0.descendants(ofType: type) }
    }
}

extension UIWindow {
    func saveSnapshot(as name: String) {
        picture().saveSnapshot(as: name)
    }

    func picture() -> UIImage {
        UIGraphicsImageRenderer(bounds: bounds).image { _ in
            drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
    }
}

extension UIImage {
    /// Keeps a picture for a person to look at, when the checkout has a `.out` folder; CI's has none.
    func saveSnapshot(as name: String) {
        let out = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: ".out")
        guard FileManager.default.fileExists(atPath: out.path(percentEncoded: false)) else { return }
        try? pngData()?.write(to: out.appending(path: "\(name).png"))
    }

    func brightness(at point: CGPoint) -> CGFloat? {
        guard let image = cgImage else { return nil }
        let (x, y) = (Int(point.x * scale), Int(point.y * scale))
        guard (0..<image.width).contains(x), (0..<image.height).contains(y) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: -x, y: y + 1 - image.height, width: image.width, height: image.height))
            return context != nil
        }
        return drawn ? CGFloat(Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / (3 * 255) : nil
    }
}
#endif
