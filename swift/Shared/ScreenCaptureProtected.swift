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
        field.translatesAutoresizingMaskIntoConstraints = true
        field.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        return field
    }()

    private let hostingController: UIHostingController<AnyView> = {
        let controller = UIHostingController<AnyView>(rootView: AnyView(EmptyView()))
        if #available(iOS 16.0, *) {
            controller.sizingOptions = .intrinsicContentSize
        }
        return controller
    }()
    private weak var currentHost: UIView?
    private var hostingConstraints: [NSLayoutConstraint] = []
    private var cachedNaturalHeight: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
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

    func fitting(_ proposal: ProposedViewSize) -> CGSize? {
        let pw = finiteProposal(proposal.width)
        let ph = finiteProposal(proposal.height)

        if pw == nil && ph == nil {
            return nil
        }

        if let pw, let ph {
            return CGSize(width: pw, height: ph)
        }

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

    private func keepHostedContentOnTop() {
        guard let host = currentHost,
              hostingController.view.superview === host,
              host.subviews.last !== hostingController.view
        else { return }
        host.bringSubviewToFront(hostingController.view)
    }

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
