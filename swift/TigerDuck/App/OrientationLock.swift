import SwiftUI
import UIKit

/// Process-wide orientation lock consulted by `PushAppDelegate`'s
/// `application(_:supportedInterfaceOrientationsFor:)`. Views push a mask via
/// `.lockOrientation(...)` while they're on screen and receive a token; the
/// lock falls back to the device-default mask (taken from Info.plist) when
/// nothing is pushed.
///
/// Locks are kept on a stack so that two concurrently visible owners (e.g.
/// multiple `LibraryView` instances reachable from the tab bar, Home
/// shortcuts, and More navigation) don't clear each other's lock when one
/// disappears.
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

    private var stack: [Entry] = []

    private init() {}

    /// The currently active mask — the top of the stack, or the device
    /// default when nothing is pushed.
    var mask: UIInterfaceOrientationMask {
        stack.last?.mask ?? Self.deviceDefaultMask()
    }

    /// Push `newMask` and return a token the caller must hand back to
    /// `release(_:)` so later locks aren't accidentally cleared.
    @discardableResult
    func push(_ newMask: UIInterfaceOrientationMask) -> Token {
        let entry = Entry(token: Token(), mask: newMask)
        stack.append(entry)
        applyToActiveWindowScene(mask)
        return entry.token
    }

    /// Remove the entry identified by `token`. If it was the top of the
    /// stack, the next mask down (or the device default) takes over.
    func release(_ token: Token) {
        let before = stack.count
        stack.removeAll { $0.token == token }
        guard stack.count != before else { return }
        applyToActiveWindowScene(mask)
    }

    private func applyToActiveWindowScene(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    private static func deviceDefaultMask() -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    }
}

private struct OrientationLockModifier: ViewModifier {
    let mask: UIInterfaceOrientationMask
    @State private var token: OrientationLock.Token?

    func body(content: Content) -> some View {
        content
            .onAppear {
                if token == nil {
                    token = OrientationLock.shared.push(mask)
                }
            }
            .onDisappear {
                if let token {
                    OrientationLock.shared.release(token)
                }
                token = nil
            }
    }
}

extension View {
    /// Locks the active scene to `mask` while the view is on screen and
    /// stacks with other concurrently pushed locks; reverts to the device
    /// default once the last lock is released. Used by Library QR code to
    /// keep the pass aligned regardless of device rotation.
    func lockOrientation(_ mask: UIInterfaceOrientationMask) -> some View {
        modifier(OrientationLockModifier(mask: mask))
    }
}
