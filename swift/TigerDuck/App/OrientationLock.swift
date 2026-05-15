import SwiftUI
import UIKit

/// Per-scene orientation lock consulted by `PushAppDelegate`'s
/// `application(_:supportedInterfaceOrientationsFor:)`. Views push a mask via
/// `.lockOrientation(...)` while they're on screen and receive a token; the
/// lock falls back to the device-default mask (taken from Info.plist) when
/// nothing is pushed for that scene.
///
/// Locks are stacked per `UIWindowScene` so that:
///  - Multiple concurrently visible owners in the same scene (e.g. multiple
///    `LibraryView` instances reachable from the tab bar, Home shortcuts,
///    and More navigation) don't clear each other's lock when one
///    disappears.
///  - On iPad multi-window setups, locking in one scene doesn't affect the
///    other scenes' supported orientations.
@MainActor
final class OrientationLock {
    static let shared = OrientationLock()

    struct Token: Hashable, Sendable {
        fileprivate let id: UUID
        fileprivate init() { id = UUID() }
    }

    private struct Entry {
        let token: Token
        let mask: UIInterfaceOrientationMask
    }

    /// Per-scene push stacks, keyed by scene identity. The top of each stack
    /// is that scene's active mask. Empty stacks are cleared so vanished
    /// scenes don't linger in the dictionary.
    private var stacks: [ObjectIdentifier: [Entry]] = [:]

    private init() {}

    /// The active mask for the given window/scene, or the device default
    /// when nothing is pushed for that scene.
    func mask(for scene: UIWindowScene?) -> UIInterfaceOrientationMask {
        guard let scene,
              let top = stacks[ObjectIdentifier(scene)]?.last
        else { return Self.deviceDefaultMask() }
        return top.mask
    }

    /// Push `newMask` onto `scene`'s stack and request the OS to honor it.
    /// Returns a token the caller must hand back to `release(_:from:)` so
    /// later locks aren't accidentally cleared.
    @discardableResult
    func push(_ newMask: UIInterfaceOrientationMask, on scene: UIWindowScene) -> Token {
        let entry = Entry(token: Token(), mask: newMask)
        stacks[ObjectIdentifier(scene), default: []].append(entry)
        apply(to: scene)
        return entry.token
    }

    /// Remove the entry identified by `token` from `scene`'s stack. If it
    /// was the top of the stack, the next mask down (or the device default)
    /// takes over.
    func release(_ token: Token, from scene: UIWindowScene) {
        let key = ObjectIdentifier(scene)
        guard var stack = stacks[key] else { return }
        let before = stack.count
        stack.removeAll { $0.token == token }
        guard stack.count != before else { return }
        if stack.isEmpty {
            stacks.removeValue(forKey: key)
        } else {
            stacks[key] = stack
        }
        apply(to: scene)
    }

    private func apply(to scene: UIWindowScene) {
        let active = mask(for: scene)
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: active)) { _ in }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    private static func deviceDefaultMask() -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    }
}

private struct OrientationLockModifier: ViewModifier {
    let mask: UIInterfaceOrientationMask
    @State private var registration: Registration?

    func body(content: Content) -> some View {
        content
            .background(
                SceneFinder { newScene in
                    bind(to: newScene)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            )
            .onDisappear { releaseRegistration() }
    }

    private func bind(to scene: UIWindowScene?) {
        if registration?.scene === scene { return }
        releaseRegistration()
        guard let scene else { return }
        let token = OrientationLock.shared.push(mask, on: scene)
        registration = Registration(token: token, scene: scene)
    }

    private func releaseRegistration() {
        if let current = registration, let scene = current.scene {
            OrientationLock.shared.release(current.token, from: scene)
        }
        registration = nil
    }

    @MainActor
    private final class Registration {
        let token: OrientationLock.Token
        weak var scene: UIWindowScene?

        init(token: OrientationLock.Token, scene: UIWindowScene) {
            self.token = token
            self.scene = scene
        }
    }
}

/// Tracks the `UIWindowScene` that owns the host SwiftUI view by observing
/// `didMoveToWindow`. Reports `nil` when the view leaves its window so the
/// modifier can release any lock owned by the previous scene.
private struct SceneFinder: UIViewRepresentable {
    let onScene: (UIWindowScene?) -> Void

    func makeUIView(context: Context) -> SceneTrackingView {
        SceneTrackingView(onScene: onScene)
    }

    func updateUIView(_ uiView: SceneTrackingView, context: Context) {
        uiView.onScene = onScene
    }
}

private final class SceneTrackingView: UIView {
    var onScene: (UIWindowScene?) -> Void

    init(onScene: @escaping (UIWindowScene?) -> Void) {
        self.onScene = onScene
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not available")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onScene(window?.windowScene)
    }
}

extension View {
    /// Locks the owning window scene to `mask` while the view is on screen,
    /// stacking with other concurrently pushed locks on the same scene;
    /// reverts to the device default for that scene once the last lock is
    /// released. Other scenes (on iPad multi-window) are unaffected. Used by
    /// Library QR code to keep the pass aligned regardless of device
    /// rotation.
    func lockOrientation(_ mask: UIInterfaceOrientationMask) -> some View {
        modifier(OrientationLockModifier(mask: mask))
    }
}
