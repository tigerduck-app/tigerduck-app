import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum ScreenCaptureProtectionDebugFlag {
    static let userDefaultsKey = "debug.disableScreenCaptureProtection"
}

extension View {
    ///
    func screenCaptureProtected(_ active: Bool = true) -> some View {
        modifier(ScreenCaptureProtectedModifier(active: active))
    }
}

private struct ScreenCaptureProtectedModifier: ViewModifier {
    let active: Bool

    #if DEBUG
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
            // Always wrapped, whatever `active` says. Switching between wrapped and bare content
            // rebuilds the hosted UIKit views, so a wrapped text field loses first responder and
            // the keyboard closes mid-typing. Over-protecting is harmless.
            SecureCaptureContainer(content: content)
        } else {
            content
        }
        #elseif os(macOS)
        content.background(MacSecureWindowMarker(active: active && protectionEnabled))
        #else
        content
        #endif
    }
}

#if os(iOS)

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

    // Forwarding `context.environment` into the hosted tree does not fix screen-level wraps: the
    // crash on OnboardingView's login page comes from SwiftUI-in-UIKit-in-SwiftUI bridging depth,
    // notably under TabView's lazy pages, not environment loss. Wrap small leaves only.

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
        // Interaction stays enabled so hit-testing reaches the hosted content on the canvas;
        // disabling it makes the hosted password field unfocusable and breaks the eye toggle.
        // `SecureCanvasHostingTextField` suppresses the field's own activation instead.
        field.translatesAutoresizingMaskIntoConstraints = true
        field.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        return field
    }()

    private let hostingController: UIHostingController<AnyView> = {
        let controller = UIHostingController<AnyView>(rootView: AnyView(EmptyView()))
        // Lets the hosted tree's natural size drive the hosting view's `intrinsicContentSize` once
        // mounted. The first Form layout pass can run before that view is in any hierarchy, so
        // `setRootView` also pre-measures into `cachedNaturalHeight`.
        if #available(iOS 16.0, *) {
            controller.sizingOptions = .intrinsicContentSize
        }
        return controller
    }()
    private weak var currentHost: UIView?
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
        // The hosted view is not added here: the text field's private canvas exists only after
        // UIKit lays the field out, so `layoutSubviews` parents the hosted view onto it.
        addSubview(textField)
        textField.frame = bounds
        textField.onTextInput = { [weak self] text in self?.fillHostedTextField(with: text) }
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
        // Pre-measure only until the hosted view is mounted; after that `sizingOptions` keeps the
        // intrinsic size live. Updates fire on every keystroke in a bound TextField, and
        // invalidating on each one makes the enclosing Form re-measure the row and jitter.
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

    /// UIKit layouts that size cells before SwiftUI's `sizeThatFits` gets a finite proposal,
    /// notably the `UICollectionViewListLayout` behind `Form`, ask for this first. Reporting
    /// `noIntrinsicMetric` makes the cell take its expanded-fitting default, the full screen, for
    /// one frame, so the password row flashes tall when a login sheet appears.
    /// The hosting controller's intrinsic height gives the SwiftUI tree's natural size. Width
    /// stays `noIntrinsicMetric` so HStacks still flex-fill.
    override var intrinsicContentSize: CGSize {
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

    /// Sizing rules, by which proposed dimensions are finite:
    /// - Neither: `nil`, keeping `UIView`'s no-preference behavior so SwiftUI flex-fills the
    ///   wrapper. A concrete measurement here collapses an empty `UITextField`.
    /// - Both: the proposal as given, since the parent has already sized the wrapper.
    /// - One: the proposed width if it is finite, since the parent decides the width, and the
    ///   hosted content's measured height. A height proposal is the space available, not the
    ///   space to use; echoing it makes Form rows flash tall on first paint.
    func fitting(_ proposal: ProposedViewSize) -> CGSize? {
        let pw = finiteProposal(proposal.width)
        let ph = finiteProposal(proposal.height)

        if pw == nil && ph == nil {
            return nil
        }

        // The parent sized the wrapper (`.aspectRatio`, `.frame`). Measuring the content instead
        // would let its own minimums shrink the wrapper, and an outer `.aspectRatio(1, .fit)`
        // would then snap to that smaller square: a QR code at half the phone's width.
        if let pw, let ph {
            return CGSize(width: pw, height: ph)
        }

        // One finite dimension, typically a Form row's width with an infinite height. Probe with
        // a compressed-fit height so the tree reports its minimum height; an expanded-fit probe
        // can come back unchanged from a tree not yet evaluated, painting a tall row first.
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

    /// Parents the hosted content onto the secure canvas, which carries the capture exclusion,
    /// and re-parents when UIKit rebuilds it (Dynamic Type, appearance or orientation changes).
    /// With no canvas it falls back to a subview of `self`: DEBUG asserts, since silent loss of
    /// protection is the worst outcome, and release still renders so the user is not locked out.
    /// Constraints anchor to `self`, not the canvas, which is sized by the field's text rect and
    /// collapses to near zero without text, hiding the content. They may cross hierarchies
    /// because `self` is the canvas's grandparent, and `clipsToBounds = false` on the canvas
    /// keeps it from clipping the hosted view to its own tiny frame.
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

        if hostingController.view.superview === desiredHost,
           currentHost === desiredHost {
            return
        }

        if !hostingConstraints.isEmpty {
            NSLayoutConstraint.deactivate(hostingConstraints)
            hostingConstraints = []
        }
        if hostingController.view.superview != nil {
            hostingController.view.removeFromSuperview()
        }

        desiredHost.addSubview(hostingController.view)
        currentHost = desiredHost

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

    private func fillHostedTextField(with text: String) {
        var queue: [UIView] = hostingController.view.subviews
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if let field = next as? UITextField, !(field is SecureCanvasHostingTextField),
               let all = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument) {
                field.replace(all, withText: text)
                return
            }
            queue.append(contentsOf: next.subviews)
        }
    }
}

/// `UITextField` used only for the capture-excluded canvas that `isSecureTextEntry` creates. The
/// field itself must never activate: a tap on a gap the hosted content leaves would raise the
/// keyboard and steal first responder from the password field being edited.
/// `canBecomeFirstResponder` blocks the keyboard, and `hitTest` returns `nil` for hits on the
/// field itself, so those taps reach the SwiftUI views underneath, such as a Form row's gesture.
/// It must never hold text either: AutoFill takes it for the form's password field, as its search
/// for the form's fields does not look inside a text field, and writes the password into it.
/// `insertText` and `replace` hand that text to `onTextInput` instead, so the hosted field gets it.
private final class SecureCanvasHostingTextField: UITextField {
    var onTextInput: ((String) -> Void)?

    override var canBecomeFirstResponder: Bool { false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    override func insertText(_ text: String) {
        onTextInput?(text)
    }

    override func replace(_ range: UITextRange, withText text: String) {
        onTextInput?(text)
    }
}

#endif

#if os(macOS)

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
        // The view can go away before `updateNSView` clears `active`, as when a sheet closes
        // mid-toggle. NSView deinit runs on the main thread, so `assumeIsolated` balances the
        // ref-count now; a later run-loop turn would briefly strand `sharingType = .none`.
        MainActor.assumeIsolated {
            if active, let previous = heldWindow {
                MacSecureWindowRegistry.release(previous)
            }
        }
    }
}

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
        if entry.preexisting != .none {
            window.sharingType = entry.preexisting
        }
    }
}

#endif
