#if canImport(UIKit)
import UIKit

extension UIView {
    /// The views of `type` below this one, depth first: how a hosted-window test finds the UIKit
    /// views SwiftUI drew.
    func descendants<View: UIView>(ofType type: View.Type) -> [View] {
        subviews.flatMap { [$0 as? View].compactMap { $0 } + $0.descendants(ofType: type) }
    }
}
#endif
