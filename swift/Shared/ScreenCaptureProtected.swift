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
    ///
    /// **Note:** uses `UIHostingController` internally, which establishes
    /// a fresh SwiftUI environment scope and drops anything the parent
    /// injected via `@Environment(...)`. Safe on small leaf views with no
    /// environment dependency (PasswordField, LibraryQRCodeView); breaks
    /// when wrapping a full screen that reads `appState`, etc. — wrap the
    /// individual sensitive leaves instead.
    func screenCaptureProtected(_ active: Bool = true) -> some View {
        modifier(ScreenCaptureProtectedModifier(active: active))
    }
}

private struct ScreenCaptureProtectedModifier: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        #if os(iOS)
        // The wrapper is ALWAYS applied on iOS, regardless of `active`.
        // Toggling between `SecureCaptureContainer { content }` and the
        // bare `content` is a structural change in SwiftUI's view tree,
        // which re-creates the hosted UIView subtree on every flip — and
        // any bridged UITextField inside (e.g. PasswordField's underlying
        // input) loses first responder, dismissing the keyboard while the
        // user was typing. A permanently-present wrapper costs only one
        // hidden UITextField plus a UIHostingController and is otherwise
        // transparent (sizing forwards the parent's proposal verbatim).
        // When `active` is conceptually false, the wrapper's secure
        // canvas is still in place; it just protects content that the
        // caller didn't consider sensitive, which is harmless.
        SecureCaptureContainer(content: content)
        #elseif os(macOS)
        // macOS doesn't have the iOS structural-identity problem: the
        // marker is an `NSViewRepresentable` placed as `.background`, so
        // toggling `active` updates the same marker instance without
        // disturbing the foreground content tree. Keeping the conditional
        // here lets the window's `sharingType` revert to its prior value
        // when protection is no longer needed.
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

    // Note: tried forwarding `context.environment` into the hosted tree
    // via `.environment(\.self, env)` so screen-level wraps could see
    // `@Environment(AppState.self)`. Didn't help — the crash on
    // OnboardingView's login page reproduced unchanged, which means the
    // root cause isn't environment loss. It's the depth of SwiftUI ↔
    // UIKit ↔ SwiftUI bridging when a non-trivial SwiftUI tree is
    // hosted inside a `UIViewRepresentable` inside another SwiftUI
    // hierarchy (notably TabView's lazy page lifecycle). Apple does not
    // expose a way around this; the secure-canvas wrap stays limited to
    // small leaves (PasswordField, LibraryQRCodeView).

    /// SwiftUI sizing for the wrapper. The strategy is dimension-by-dimension:
    ///
    /// - When the parent supplies a finite value for a dimension, return it
    ///   verbatim. The wrapper is a transparent protection layer; if the
    ///   parent has decided how wide / tall we are, we have no business
    ///   overriding that.
    /// - When the parent leaves a dimension unspecified, ask the
    ///   `UIHostingController` for the hosted SwiftUI tree's preferred
    ///   value in that dimension (e.g. a QR card's natural height).
    /// - When BOTH dimensions are unspecified — typically an HStack's
    ///   intrinsic-sizing probe asking "how wide do you want to be?" —
    ///   return `nil`. This defers to the default `UIView`
    ///   `intrinsicContentSize = (noIntrinsicMetric, noIntrinsicMetric)`,
    ///   which SwiftUI reads as "no preference, fill me." That's how the
    ///   unwrapped `_PasswordTextField` already behaves; returning a
    ///   concrete measurement here was making the host controller report
    ///   the empty textfield's tiny intrinsic size, collapsing the field
    ///   when the password is revealed.
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

    private let hostingController: UIHostingController<AnyView> = {
        let controller = UIHostingController<AnyView>(rootView: AnyView(EmptyView()))
        // Make the hosted SwiftUI tree's natural size drive
        // `hostingController.view.intrinsicContentSize` automatically when
        // it eventually mounts. Belt + suspenders: we also pre-measure
        // in `setRootView` and cache the result on `cachedNaturalHeight`
        // so the first Form layout pass (which can fire BEFORE the hosted
        // view is in any hierarchy) has a sized answer ready.
        if #available(iOS 16.0, *) {
            controller.sizingOptions = .intrinsicContentSize
        }
        return controller
    }()
    private var didInstallContent = false
    /// Natural height of the hosted SwiftUI content, computed eagerly when
    /// `setRootView` is called. Used as the intrinsic height before UIKit
    /// has mounted the hosting controller's view. Without this, the first
    /// `UICollectionViewListLayout` sizing pass — which runs before our
    /// hosted view is in any hierarchy — sees `noIntrinsicMetric` and
    /// falls back to the cell's fitting-expanded default, rendering the
    /// password row at full sheet height for one frame.
    private var cachedNaturalHeight: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        // The text field is added first so its private canvas view is the
        // direct sibling of the hosted view. The hosting controller's view
        // gets parented onto the canvas in `layoutSubviews` once UIKit
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
        // Pre-measure with a "wide but compact" probe — gives the SwiftUI
        // tree plenty of horizontal room and asks for its minimum natural
        // height. `UIHostingController.sizeThatFits(in:)` works even when
        // the controller's view isn't yet in any hierarchy, so this
        // resolves to a real height (~30pt for the password row) before
        // the first Form sizing pass.
        let probe = CGSize(
            width: UIView.layoutFittingExpandedSize.width,
            height: UIView.layoutFittingCompressedSize.height
        )
        let measured = hostingController.sizeThatFits(in: probe)
        if measured.height > 0 {
            cachedNaturalHeight = measured.height
        }
        invalidateIntrinsicContentSize()
    }

    /// UIKit layout systems that pre-size before SwiftUI's `sizeThatFits`
    /// gets a finite proposal (notably `UICollectionViewListLayout`, which
    /// backs SwiftUI `Form`) ask for `intrinsicContentSize` first. Reporting
    /// `noIntrinsicMetric` here means the cell falls back to its layout-
    /// fitting-expanded default — which is the full screen — for one frame,
    /// producing the "tall password row flash, then snaps to normal" you
    /// see when a login sheet first appears.
    ///
    /// Forwarding to the hosting controller's view (which is itself wired up
    /// with `sizingOptions = .intrinsicContentSize` in the initialiser)
    /// gives the SwiftUI tree's natural size directly. Width is dropped to
    /// no-intrinsic so HStacks still flex-fill horizontally.
    override var intrinsicContentSize: CGSize {
        // Prefer the hosting controller's live intrinsic size (kept fresh
        // by `sizingOptions = .intrinsicContentSize` once mounted); fall
        // back to the eager pre-measurement from `setRootView` so first-pass
        // sizing has a real answer before the hosted view is in any
        // hierarchy.
        let inner = hostingController.view.intrinsicContentSize.height
        let height: CGFloat
        if inner > 0 {
            height = inner
        } else if cachedNaturalHeight > 0 {
            height = cachedNaturalHeight
        } else {
            height = UIView.noIntrinsicMetric
        }
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }

    /// Sizing strategy:
    ///
    /// - **Width**: when the parent supplies a finite proposal, return it
    ///   verbatim. The wrapper is a transparent protection layer for
    ///   horizontal flex layouts (HStack rows, full-width cards) — the
    ///   parent has decided how wide we are.
    /// - **Height**: ALWAYS return the inner content's measured height
    ///   from `UIHostingController.sizeThatFits`, never the parent's
    ///   proposed height. SwiftUI's height proposal means "this is the
    ///   space available," not "use this much." Returning a finite parent
    ///   proposal verbatim caused initial-layout flicker in Form / UICVC
    ///   rows: the first layout pass proposed an oversized height, the
    ///   wrapper honored it, and the row rendered tall for a frame
    ///   before the next pass settled to the natural row height.
    /// - **Both unspecified**: return `nil` so the wrapper falls back to
    ///   `UIView`'s no-intrinsic-preference behavior (SwiftUI flex-fills).
    ///   Returning a concrete measurement here makes empty
    ///   `UITextField`s collapse to their tiny intrinsic size.
    func fitting(_ proposal: ProposedViewSize) -> CGSize? {
        let pw = finiteProposal(proposal.width)
        let ph = finiteProposal(proposal.height)

        if pw == nil && ph == nil {
            return nil
        }

        // Probe the hosting controller for the content's preferred size.
        // Use compressed-fit for the height probe so the SwiftUI tree
        // returns its minimum required vertical extent — proposing
        // expanded-fit height to a tree that hasn't yet evaluated risks
        // the controller echoing the probe back as the "preferred" size,
        // which is the tall-row-on-first-paint bug.
        let probe = CGSize(
            width: pw ?? UIView.layoutFittingExpandedSize.width,
            height: UIView.layoutFittingCompressedSize.height
        )
        let measured = hostingController.sizeThatFits(in: probe)

        // If the live measurement came back as 0 (hosted tree not yet
        // ready), fall back to the eager pre-measurement we cached when
        // `setRootView` was called. That value was computed against the
        // same compressed-height probe, so it's the right comparison.
        let height: CGFloat
        if measured.height > 0 {
            height = measured.height
        } else if cachedNaturalHeight > 0 {
            height = cachedNaturalHeight
        } else {
            height = measured.height
        }

        return CGSize(
            width: pw ?? measured.width,
            height: height
        )
    }

    private func finiteProposal(_ value: CGFloat?) -> CGFloat? {
        guard let value, value.isFinite else { return nil }
        return value
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
