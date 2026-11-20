#if canImport(UIKit)
import UIKit

extension UIApplication {
    /// Forces the current first responder to resign, dismissing any visible
    /// keyboard regardless of which control owns it. Use when programmatic
    /// `@FocusState = nil` is silently ignored — notably with our wrapped
    /// `UITextField`-backed `PasswordField`, which intentionally does not
    /// resign on transient focus-state writes.
    static func dismissKeyboard() {
        shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
#endif
