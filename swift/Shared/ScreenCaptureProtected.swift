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
/// Debug-only toggle that disables `.screenCaptureProtected(...)` system-wide.
///
/// Exposed in **Settings → Developer → Disable screen-capture protection**
/// (DEBUG builds only). Useful when the secure-canvas wrap interferes with
/// SwiftUI sizing during layout-bug investigation, or when recording a demo
/// where the password / QR needs to actually appear in the recording.
///
/// Persisted via `UserDefaults` so it survives app restarts. Compiled out
/// of release builds — the production code path is unchanged.
enum ScreenCaptureProtectionDebugFlag {
    static let userDefaultsKey = "debug.disableScreenCaptureProtection"
}

extension View {
    /// Wraps this view so it is excluded from screen capture.
    ///
    /// **Per-platform `active` semantics — read carefully, they are
    /// asymmetric:**
    /// - macOS: `active` toggles `NSWindow.sharingType` between `.none` and
    ///   the window's preexisting value. Passing a dynamic boolean works
    ///   as expected.
    /// - iOS / iPadOS: the wrapper is **always** applied regardless of
    ///   `active`. Toggling between wrapped and unwrapped on iOS is a
    ///   SwiftUI structural-identity change that rebuilds the hosted
    ///   `UIView` subtree, which drops the keyboard mid-typing on any
    ///   embedded `UITextField`. The `active` argument exists for API
    ///   symmetry but is ignored on iOS; over-protection on this platform
    ///   is harmless.
    /// - watchOS: no-op (no public capture-exclusion API exists).
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

    #if DEBUG
    // Reactive in DEBUG so toggling the Settings → Developer switch
    // immediately re-evaluates the modifier (and adds/removes the
    // secure wrap) without restarting the app. In release builds the
    // flag is compiled out entirely.
    @AppStorage(ScreenCaptureProtectionDebugFlag.userDefaultsKey) private var debugDisabled = false
    #endif

    private var protectionEnabled: Bool {
        #if DEBUG
        return !debugDisabled
        #else
        return true
        #endif
    }

    func body(content: Content) -> some View {
        #if os(iOS)
        if protectionEnabled {
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
        } else {
            // DEBUG developer toggle: skip the entire secure-canvas
            // pipeline so the protected view renders natively (and shows
            // up in screenshots / screen recordings).
            content
        }
        #elseif os(macOS)
        // macOS doesn't have the iOS structural-identity problem: the
        // marker is an `NSViewRepresentable` placed as `.background`, so
        // toggling `active` updates the same marker instance without
        // disturbing the foreground content tree. Keeping the conditional
        // here lets the window's `sharingType` revert to its prior value
        // when protection is no longer needed.
        //
        // DEBUG bypass: feeding `active: false` through the same marker
        // keeps the ref-count balanced (so any preexisting `.none` from
        // another caller is preserved) while letting this view's pixels
        // back into screen recordings / Screen Sharing.
        content.background(MacSecureWindowMarker(active: active && protectionEnabled))
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

    /// SwiftUI sizing for the wrapper. **The width and height rules are
    ///  deliberately asymmetric** — see `fitting(_:)` below for the
    ///  full rationale, summarised here:
    ///
    /// - **Width**: return the parent's finite proposal verbatim. The
    ///   wrapper is a transparent protection layer for horizontal flex
    ///   layouts (HStack rows, full-width cards).
    /// - **Height**: always measure from the hosted content; do NOT
    ///   echo the parent's height proposal back. SwiftUI's height
    ///   proposal means "this is the space available," not "use this
    ///   much" — returning it verbatim caused initial-layout flicker
    ///   in Form / UICVC rows where the first pass proposes an
    ///   oversized height.
    /// - **Both unspecified**: return `nil` so the wrapper falls back to
    ///   `UIView`'s no-intrinsic-preference behavior (SwiftUI flex-fills).
    ///   Returning a concrete measurement here made empty `UITextField`s
    ///   collapse to their tiny intrinsic size.
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
    /// The `UIView` we last parented `hostingController.view` onto — used to
    /// detect when UIKit has replaced the secure canvas (e.g. on trait/locale
    /// rebuild) so we can re-parent onto the new one. `nil` means the hosted
    /// content has not been installed yet.
    private weak var currentHost: UIView?
    /// Cached so we can deactivate when we re-parent. `nil` before first
    /// install or after explicit deactivation.
    private var hostingConstraints: [NSLayoutConstraint] = []
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

    /// Attach/detach the hosting controller as a proper child view
    /// controller whenever our window changes. UIKit's containment rules
    /// require `addChild` before `addSubview` of a controller's view —
    /// otherwise appearance callbacks (`viewWillAppear`/`Disappear`),
    /// trait propagation, and Dynamic Type updates skip the hosted SwiftUI
    /// tree, and SwiftUI logs the diagnostic 'Adding a UIHostingController
    /// as a child of a UIView without its UIViewController parent is
    /// unsupported'.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        let resolvedParent = window != nil ? nearestParentViewController() : nil
        let currentParent = hostingController.parent

        if currentParent === resolvedParent { return }

        if currentParent != nil {
            hostingController.willMove(toParent: nil)
            hostingController.removeFromParent()
        }
        if let resolvedParent {
            resolvedParent.addChild(hostingController)
            hostingController.didMove(toParent: resolvedParent)
        }
    }

    /// Walks the `next` responder chain to find the nearest enclosing
    /// `UIViewController`. SwiftUI parents `UIViewRepresentable` content
    /// via a hosting controller, so this is usually reachable in one or
    /// two hops once the view is in a window.
    private func nearestParentViewController() -> UIViewController? {
        var responder: UIResponder? = self.next
        while let current = responder {
            if let vc = current as? UIViewController { return vc }
            responder = current.next
        }
        return nil
    }

    func setRootView(_ view: AnyView) {
        hostingController.rootView = view
        // The eager pre-measurement only matters before the hosting
        // controller's view is in the hierarchy — once mounted,
        // `sizingOptions = .intrinsicContentSize` keeps the live
        // intrinsic size in sync automatically. Re-probing on every
        // SwiftUI update (which fires on every keystroke for a bound
        // TextField) used to call `invalidateIntrinsicContentSize` every
        // character, forcing the enclosing Form / UICollectionView to
        // re-measure the row mid-typing and producing visible jitter.
        // Skip the eager probe + invalidation once the view is mounted.
        guard hostingController.view.window == nil else { return }

        let probe = CGSize(
            width: UIView.layoutFittingExpandedSize.width,
            height: UIView.layoutFittingCompressedSize.height
        )
        let measured = hostingController.sizeThatFits(in: probe)
        guard measured.height > 0, measured.height != cachedNaturalHeight else { return }
        cachedNaturalHeight = measured.height
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
    /// - **Height (content has intrinsic row height — PasswordField,
    ///    inline rows)**: return the inner content's measured height,
    ///    never the parent's proposed height. SwiftUI's height proposal
    ///    in Form / UICVC rows means "this is the space available," not
    ///    "use this much" — honoring it caused initial-layout flicker
    ///    (tall row flash on first paint).
    /// - **Height (content has NO intrinsic row height — image / QR
    ///    matrix wrapped inside `.aspectRatio(...).fit`)**: honor the
    ///    parent's finite proposal, because the parent's
    ///    `.aspectRatio` modifier has already computed the specific
    ///    height we should occupy (e.g. `(phone_w, phone_w)` for a
    ///    square QR). Detecting "no intrinsic height" via
    ///    `measured.height == 0 && cachedNaturalHeight == 0`.
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

        // When the parent supplies BOTH dimensions, it has already
        // computed a specific size — typically via `.aspectRatio(...).fit`,
        // `.frame(width:height:)`, or `.frame(idealWidth:idealHeight:)`.
        // Honor it verbatim. Measuring the hosted content here lets the
        // inner content's intrinsic minimums (e.g. a `ProgressView`'s
        // `minHeight: 200` while the QR is loading) shrink the wrapper,
        // and the outer `.aspectRatio(1, .fit)` then snaps to that smaller
        // square — producing the "QR is half phone width" symptom.
        if let pw, let ph {
            return CGSize(width: pw, height: ph)
        }

        // Single-dimension proposal: typical Form / list-row layout where
        // width is finite and height is `.infinity`. Probe the hosting
        // controller for the content's preferred size. Use compressed-fit
        // for the height probe so the SwiftUI tree returns its minimum
        // required vertical extent — proposing expanded-fit height to a
        // tree that hasn't yet evaluated risks the controller echoing
        // the probe back as the "preferred" size (tall-row-on-first-paint).
        let probe = CGSize(
            width: pw ?? UIView.layoutFittingExpandedSize.width,
            height: UIView.layoutFittingCompressedSize.height
        )
        let measured = hostingController.sizeThatFits(in: probe)

        let height: CGFloat
        if measured.height > 0 {
            height = measured.height
        } else if cachedNaturalHeight > 0 {
            height = cachedNaturalHeight
        } else {
            height = 0
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
        keepHostedContentOnTop()
    }

    /// Parents the hosted content onto the text field's secure canvas view,
    /// re-parenting if UIKit has replaced the canvas since the last install
    /// (e.g. after a Dynamic Type / interface style / orientation change
    /// rebuilds the text field's private rendering chain).
    ///
    /// Tries the canvas first — the actual screen-capture exclusion lives
    /// there — and falls back to a regular subview of `self` if UIKit ever
    /// stops producing a canvas. The fallback `assertionFailure`s in DEBUG
    /// because silent protection loss is the worst outcome for this code;
    /// in release, the content still renders so the user isn't locked out.
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
        guard bounds.width > 0, bounds.height > 0 else { return }

        let desiredHost: UIView
        let canvas = secureCanvasView(in: textField)
        if let canvas {
            canvas.clipsToBounds = false
            desiredHost = canvas
        } else {
            #if DEBUG
            assertionFailure("ScreenCaptureProtected: secure canvas not found — capture protection is silently disabled. Has UIKit renamed its private text-layout class?")
            #endif
            desiredHost = self
        }

        // Already parented on the right host? Nothing to do — avoids a
        // pointless detach/reattach churn on every layout pass.
        if hostingController.view.superview === desiredHost,
           currentHost === desiredHost {
            return
        }

        // Re-parent: drop old constraints and superview link first so
        // autolayout doesn't try to simultaneously satisfy stale and
        // fresh constraints across two superviews.
        if !hostingConstraints.isEmpty {
            NSLayoutConstraint.deactivate(hostingConstraints)
            hostingConstraints = []
        }
        if hostingController.view.superview != nil {
            hostingController.view.removeFromSuperview()
        }

        desiredHost.addSubview(hostingController.view)
        currentHost = desiredHost

        // Anchor to `self` regardless of which host we picked, so the
        // hosted view always fills the SwiftUI-allocated frame. When the
        // host is `self` (fallback), this is a regular same-superview
        // constraint; when the host is the canvas, it is a legal
        // cross-hierarchy constraint that bypasses the canvas's text-driven
        // intrinsic size.
        let newConstraints = [
            hostingController.view.topAnchor.constraint(equalTo: topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: bottomAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ]
        NSLayoutConstraint.activate(newConstraints)
        hostingConstraints = newConstraints
    }

    /// Ensures the hosted SwiftUI view paints last among the canvas's
    /// children. UIKit may re-add private decorations (caret, placeholder
    /// label) under the canvas after we first installed — bringing our view
    /// to the front on every layout pass keeps them from painting over the
    /// hosted password row. Non-destructive: we leave UIKit's own subviews
    /// in place rather than `removeFromSuperview`-ing them, which could
    /// upset the secure-canvas rendering pipeline.
    private func keepHostedContentOnTop() {
        guard let host = currentHost,
              hostingController.view.superview === host,
              host.subviews.last !== hostingController.view
        else { return }
        host.bringSubviewToFront(hostingController.view)
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

@MainActor
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
        // dismissed mid-toggle). NSView deinit always lands on the main
        // thread, so `assumeIsolated` lets us synchronously balance the
        // refcount without bouncing through another runloop turn (which
        // would briefly leave `sharingType = .none` stranded on a
        // window the marker no longer cares about).
        MainActor.assumeIsolated {
            if active, let previous = heldWindow {
                MacSecureWindowRegistry.release(previous)
            }
        }
    }
}

/// Per-window reference counter for `NSWindow.sharingType = .none`. Mirrors
/// the Android `SecureWindowRegistry` design: remembers whether `sharingType`
/// was already restricted before our first acquire so the last release does
/// not strip protection an unrelated caller had installed independently.
///
/// `@MainActor` because the storage is a plain dictionary mutated from both
/// SwiftUI view lifecycle (always main thread) and `deinit` (runs on
/// whichever thread released the last reference). Pinning the registry to
/// the main actor guarantees both paths serialize, so a race during a sheet
/// dismiss can't corrupt the hash table or strand `sharingType = .none` on
/// a recycled window.
@MainActor
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
