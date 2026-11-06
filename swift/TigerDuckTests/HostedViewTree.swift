#if canImport(UIKit)
import UIKit

extension UIView {
    func descendants<View: UIView>(ofType type: View.Type) -> [View] {
        subviews.flatMap { [$0 as? View].compactMap { $0 } + $0.descendants(ofType: type) }
    }

    /// No layer under the view is animating, so a picture taken now shows where things end up.
    var isStill: Bool { layer.isStill }
}

extension CALayer {
    var isStill: Bool {
        (animationKeys() ?? []).isEmpty && (sublayers ?? []).allSatisfy(\.isStill)
    }
}

extension UIWindow {
    /// Keeps a picture of the window for a person to look at, when the checkout has a `.out`
    /// folder; CI's has none.
    func saveSnapshot(as name: String) {
        let out = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: ".out")
        guard FileManager.default.fileExists(atPath: out.path(percentEncoded: false)) else { return }
        let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in
            drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: out.appending(path: "\(name).png"))
    }
}
#endif
