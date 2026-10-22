#if canImport(UIKit)
import UIKit

extension UIView {
    func descendants<View: UIView>(ofType type: View.Type) -> [View] {
        subviews.flatMap { [$0 as? View].compactMap { $0 } + $0.descendants(ofType: type) }
    }
}
#endif
