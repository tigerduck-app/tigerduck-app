#if canImport(UIKit)
import UIKit

extension UIView {
    func descendants<View: UIView>(ofType type: View.Type) -> [View] {
        subviews.flatMap { [$0 as? View].compactMap { $0 } + $0.descendants(ofType: type) }
    }
}

extension UIWindow {
    func saveSnapshot(as name: String) {
        UIGraphicsImageRenderer(bounds: bounds).image { _ in
            drawHierarchy(in: bounds, afterScreenUpdates: true)
        }.saveSnapshot(as: name)
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
}
#endif
