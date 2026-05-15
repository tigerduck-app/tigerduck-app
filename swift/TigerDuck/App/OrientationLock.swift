import SwiftUI
import UIKit

/// Process-wide orientation lock consulted by `PushAppDelegate`'s
/// `application(_:supportedInterfaceOrientationsFor:)`. Views push a mask via
/// `.lockOrientation(...)` while they're on screen; the lock falls back to the
/// device-default mask (taken from Info.plist) when nothing is pushed.
@MainActor
final class OrientationLock {
    static let shared = OrientationLock()

    private(set) var mask: UIInterfaceOrientationMask

    private init() {
        mask = Self.deviceDefaultMask()
    }

    func push(_ newMask: UIInterfaceOrientationMask) {
        mask = newMask
        applyToActiveWindowScene(newMask)
    }

    func reset() {
        let restored = Self.deviceDefaultMask()
        mask = restored
        applyToActiveWindowScene(restored)
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

    func body(content: Content) -> some View {
        content
            .onAppear { OrientationLock.shared.push(mask) }
            .onDisappear { OrientationLock.shared.reset() }
    }
}

extension View {
    /// Locks the active scene to `mask` while the view is on screen; reverts
    /// to the device default when it disappears. Used by Library QR code to
    /// keep the pass aligned on iPad regardless of device rotation.
    func lockOrientation(_ mask: UIInterfaceOrientationMask) -> some View {
        modifier(OrientationLockModifier(mask: mask))
    }
}
