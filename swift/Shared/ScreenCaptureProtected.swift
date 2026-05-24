import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Hides a SwiftUI subtree from screen capture — screenshots, screen
/// recording, AirPlay/Sidecar mirroring — at the OS level.
///
/// Modeled on the Android `SecureScreen` composable (`FLAG_SECURE`). Android
/// has a documented per-window flag; iOS/iPadOS does not, so the only path
/// that actually blanks pixels in captured frames is to host the protected
/// view inside a `UITextField` whose `isSecureTextEntry = true` is on. The
/// system rendering pipeline treats that text-entry canvas layer as
/// non-screenshotable, and any subview parented to it inherits the same
/// exclusion. This is the same pattern used by Bitwarden, 1Password, Apple
/// Wallet pass previews, etc.
///
/// Platform behavior:
/// - iOS / iPadOS: full protection via the secure-text-entry canvas trick.
///   Screenshots come out blank in the protected region; the `Image` is also
///   absent from screen recordings and AirPlay mirroring.
/// - macOS: sets `NSWindow.sharingType = .none` on the hosting window while
///   any protected subtree is on screen, reference-counted so concurrent
///   callers don't clear each other's request. Excludes the window from
///   `CGWindowList`-based screen captures + Screen Sharing.
/// - watchOS: **no public API exists.** The modifier is a no-op there. The
///   only screen-capture vector on watchOS is the user's deliberate
///   side-button + Digital Crown press, so the residual exposure is
///   bounded by physical possession of the device.
extension View {
    /// Wraps this view so it is excluded from screen capture while `active`
    /// is true. Toggling `active` reattaches/detaches the protection; the
    /// content itself is not torn down across toggles.
    func screenCaptureProtected(_ active: Bool = true) -> some View {
        modifier(ScreenCaptureProtectedModifier(active: active))
    }
}

private struct ScreenCaptureProtectedModifier: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        #if os(iOS)
        if active {
            SecureCaptureContainer(content: content)
        } else {
            content
        }
        #elseif os(macOS)
        content.background(MacSecureWindowMarker(active: active))
        #else
        content
        #endif
    }
}

// MARK: - iOS / iPadOS: UITextField secure-canvas host

#if os(iOS)

/// `UIViewRepresentable` that parents the SwiftUI `content` inside the
/// secure-text-entry canvas layer of a sacrificial `UITextField`.
///
/// The text field is fully covered by the hosted content (its own caret /
/// placeholder / first-responder behavior is intentionally suppressed). The
/// canvas view is only created after the text field is attached to a window
/// and laid out at least once, so subview parenting and constraint setup
/// run from `layoutSubviews` on the first non-zero size.
private struct SecureCaptureContainer<Content: View>: UIViewRepresentable {
    let content: Content

    func makeUIView(context: Context) -> SecureCaptureHostView {
        let view = SecureCaptureHostView()
        view.setRootView(AnyView(content))
        return view
    }

    func updateUIView(_ uiView: SecureCaptureHostView, context: Context) {
        uiView.setRootView(AnyView(content))
    }

    /// Without this, the host view has no intrinsic content size and SwiftUI
    /// hands it a zero frame; `installHostedContentIfNeeded` never fires
    /// because its `bounds.width > 0` guard fails, and the protected subtree
    /// silently vanishes. Delegate to the `UIHostingController`, which can
    /// measure SwiftUI content even while not attached to the view hierarchy.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: SecureCaptureHostView,
        context: Context
    ) -> CGSize? {
        uiView.fitting(proposal)
    }
}

private final class SecureCaptureHostView: UIView {
    private let textField: SecureCanvasHostingTextField = {
        let field = SecureCanvasHostingTextField()
        field.isSecureTextEntry = true
        // Interaction stays ENABLED: hit-testing must descend into the
        // canvas subtree where the hosted SwiftUI content lives (turning
        // it off here makes the hosted password field unfocusable and
        // breaks the eye-toggle button). The text field's own activation
        // is suppressed by the subclass overrides instead — keyboard
        // never appears, and background taps fall through to siblings.
        field.translatesAutoresizingMaskIntoConstraints = true
        field.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        return field
    }()

    private let hostingController = UIHostingController<AnyView>(rootView: AnyView(EmptyView()))
    private var didInstallContent = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        // The text field is added first so its private canvas view is the
        // direct sibling of the hosted view. The hosting controller's view
        // gets re-parented onto the canvas in `layoutSubviews` once UIKit
        // has materialised it.
        addSubview(textField)
        textField.frame = bounds
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used; this view is created programmatically")
    }

    func setRootView(_ view: AnyView) {
        hostingController.rootView = view
    }

    /// Resolves the SwiftUI representable's intrinsic size for SwiftUI's
    /// parent. Uses `UIHostingController.sizeThatFits(in:)`, which produces
    /// the SwiftUI root view's natural size for the proposed dimensions
    /// without requiring the controller to be attached to a parent VC or
    /// window. `unspecified` proposals map to an unbounded target so the
    /// content reports its own preferred size (typical for QR cards, which
    /// have a square aspect ratio of fixed maxWidth).
    func fitting(_ proposal: ProposedViewSize) -> CGSize {
        let target = CGSize(
            width: proposal.width ?? UIView.layoutFittingExpandedSize.width,
            height: proposal.height ?? UIView.layoutFittingExpandedSize.height
        )
        return hostingController.sizeThatFits(in: target)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        textField.frame = bounds
        installHostedContentIfNeeded()
    }

    /// One-shot parenting of the hosted content onto the text field's
    /// secure canvas view. Tries the canvas first (the actual screen-capture
    /// exclusion lives there) and falls back to a regular subview of `self`
    /// if UIKit ever stops producing a canvas — capture protection is then
    /// lost, but the content still renders rather than going blank.
    ///
    /// Sizing is anchored to `self`, not to the canvas: the canvas is sized
    /// by the secure text field's text rect (which collapses to ~zero when
    /// the field has no text), and pinning the hosted view to it would
    /// render the SwiftUI subtree invisible. Cross-hierarchy constraints
    /// are legal because both sides share a common ancestor (`self` is the
    /// canvas's grandparent), and `clipsToBounds = false` on the canvas
    /// stops it from clipping the now-larger hosted view back to its own
    /// tiny frame.
    private func installHostedContentIfNeeded() {
        guard !didInstallContent, bounds.width > 0, bounds.height > 0 else { return }

        let host: UIView
        if let canvas = secureCanvasView(in: textField) {
            // Clear out any pre-existing subviews UIKit may have parked on
            // the canvas (placeholder labels, caret, etc.). They would
            // otherwise paint over our SwiftUI content.
            canvas.subviews.forEach { $0.removeFromSuperview() }
            canvas.clipsToBounds = false
            host = canvas
        } else {
            // Fallback: parent directly on `self`. Logs nothing because this
            // view doesn't carry a logger dependency, and a one-shot failure
            // is best surfaced via the UI itself (content still visible,
            // protection silently absent — acceptable because we never used
            // protection as the only line of defense).
            host = self
        }

        host.addSubview(hostingController.view)
        // Anchor to `self` regardless of which host we picked, so the
        // hosted view always fills the SwiftUI-allocated frame. When the
        // host is `self` (fallback), this is a regular same-superview
        // constraint; when the host is the canvas, it is a legal
        // cross-hierarchy constraint that bypasses the canvas's text-driven
        // intrinsic size.
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: bottomAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        didInstallContent = true
    }

    /// Locates the private "canvas" subview inside a secure `UITextField`
    /// without naming UIKit-internal classes. Conservative: returns the
    /// first descendant view whose class name contains "Canvas" — that
    /// matches both `_UITextLayoutCanvasView` (iOS 16+) and any future
    /// renames provided Apple keeps the substring.
    private func secureCanvasView(in field: UITextField) -> UIView? {
        var queue: [UIView] = field.subviews
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if String(describing: type(of: next)).contains("Canvas") {
                return next
            }
            queue.append(contentsOf: next.subviews)
        }
        return nil
    }
}

/// `UITextField` subclass used as the secure-canvas host. We rely on
/// `isSecureTextEntry = true` to materialise the screen-capture-excluded
/// canvas layer, but we never want the field itself to activate: a tap
/// landing on the text field's "background" (gaps the hosted content
/// doesn't cover) would normally raise the keyboard and steal first
/// responder from whatever password field the user is actually editing.
///
/// `canBecomeFirstResponder = false` blocks the keyboard. `hitTest`
/// returns `nil` when the hit terminates on `self`, so background taps
/// fall through to underlying SwiftUI views (e.g. a Form row's tap
/// gesture) instead of being silently consumed by an inert text field.
private final class SecureCanvasHostingTextField: UITextField {
    override var canBecomeFirstResponder: Bool { false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

#endif

// MARK: - macOS: NSWindow.sharingType ref-count

#if os(macOS)

/// Empty view whose lifecycle is used purely to flip `NSWindow.sharingType`
/// on the hosting window. Multiple concurrent callers (e.g. password reveal
/// inside a login sheet that itself sits inside a protected card) are
/// reference-counted by `MacSecureWindowRegistry` so the first release does
/// not clear the flag while another holder still needs it.
private struct MacSecureWindowMarker: NSViewRepresentable {
    let active: Bool

    func makeNSView(context: Context) -> MacSecureWindowMarkerView {
        MacSecureWindowMarkerView()
    }

    func updateNSView(_ nsView: MacSecureWindowMarkerView, context: Context) {
        nsView.setActive(active)
    }
}

private final class MacSecureWindowMarkerView: NSView {
    private var active = false
    private var heldWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Re-evaluate when the marker moves between windows (e.g. a sheet
        // is presented, then dismissed). `release` is a no-op if the
        // previous window had no acquire on it.
        if active, heldWindow !== window {
            if let previous = heldWindow {
                MacSecureWindowRegistry.release(previous)
            }
            heldWindow = window
            if let window {
                MacSecureWindowRegistry.acquire(window)
            }
        }
    }

    func setActive(_ newValue: Bool) {
        guard newValue != active else { return }
        active = newValue
        if newValue {
            if let window {
                MacSecureWindowRegistry.acquire(window)
                heldWindow = window
            }
        } else if let previous = heldWindow {
            MacSecureWindowRegistry.release(previous)
            heldWindow = nil
        }
    }

    deinit {
        // Capture-protected views can disappear faster than SwiftUI's
        // updateNSView lifecycle would clear `active` (e.g. a sheet is
        // dismissed mid-toggle). Releasing in deinit guarantees the
        // sharingType refcount returns to balance.
        if active, let previous = heldWindow {
            MacSecureWindowRegistry.release(previous)
        }
    }
}

/// Per-window reference counter for `NSWindow.sharingType = .none`. Mirrors
/// the Android `SecureWindowRegistry` design: remembers whether `sharingType`
/// was already restricted before our first acquire so the last release does
/// not strip protection an unrelated caller had installed independently.
private enum MacSecureWindowRegistry {
    private final class Entry {
        var count: Int
        let preexisting: NSWindow.SharingType
        init(count: Int, preexisting: NSWindow.SharingType) {
            self.count = count
            self.preexisting = preexisting
        }
    }

    private static var holders: [ObjectIdentifier: Entry] = [:]

    static func acquire(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        if let entry = holders[key] {
            entry.count += 1
            return
        }
        let previous = window.sharingType
        holders[key] = Entry(count: 1, preexisting: previous)
        if previous != .none {
            window.sharingType = .none
        }
    }

    static func release(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        guard let entry = holders[key] else { return }
        entry.count -= 1
        guard entry.count <= 0 else { return }
        holders.removeValue(forKey: key)
        // Only restore the preexisting value if we changed it. If another
        // unrelated caller had already set `.none` before us, leave it
        // alone — they own that restriction.
        if entry.preexisting != .none {
            window.sharingType = entry.preexisting
        }
    }
}

#endif
