#if os(iOS)
import UIKit

/// A `UIScreen` reference that does not keep the screen alive.
///
/// An external display can be unplugged, or a foldable's panel torn down,
/// while a view still holds its last reading. A strong reference would keep
/// the dead screen allocated and let a later write land in an object nobody
/// is looking at.
struct WeakScreen: Equatable {
    weak var screen: UIScreen?

    init(_ screen: UIScreen? = nil) {
        self.screen = screen
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.screen === rhs.screen
    }
}

/// Something whose brightness this app can pin.
///
/// `UIScreen` cannot be constructed, and a test that drove a real one would
/// be changing the brightness of whatever machine the suite runs on. The
/// protocol is the seam that lets the counting logic below — which is the
/// part that actually went wrong — be tested against a fake panel.
protocol BrightnessControllable: AnyObject {
    var brightness: CGFloat { get set }
}

extension UIScreen: BrightnessControllable {}

/// Owns the screen-brightness override the library QR page uses to stay
/// readable at a scanner.
///
/// Brightness is a process-global resource, but `LibraryView` is not a
/// single instance: the Library tab builds one, and Home and More each push
/// their own `LibraryView(embedded: true)` onto their navigation stacks. Two
/// can be alive at once, and with the override state held per view the
/// second one captured the *already boosted* `1.0` as its "pre-boost"
/// value — after which no restore could put the panel back, short of the
/// user finding Control Center.
///
/// Claims are counted, so the boost survives one instance going away while
/// another is still showing a code, and the panel is released only when the
/// last claim is dropped. Mirrors `LibraryQRCache.shared`, which is
/// process-wide for the same reason: there is one library session at a time.
@MainActor
final class LibraryBrightnessCoordinator {
    static let shared = LibraryBrightnessCoordinator()

    /// Weak: a display can be unplugged, or a foldable's panel torn down,
    /// while a claim is still registered. A strong reference would keep the
    /// dead screen allocated and let a later restore write into an object
    /// nobody is looking at.
    private weak var boostedPanel: (any BrightnessControllable)?
    private var savedBrightness: CGFloat?
    private var holders: Set<UUID> = []

    init() {}

    /// Pin `screen` at full brightness on behalf of `token`.
    ///
    /// Safe to call repeatedly — from `onAppear`, from a scene-phase change,
    /// from a screen move. The pre-boost value is captured only when moving
    /// onto a screen this coordinator is not already holding, so a value we
    /// set ourselves can never be mistaken for the user's.
    func boost(_ panel: any BrightnessControllable, token: UUID) {
        holders.insert(token)
        guard boostedPanel !== panel else { return }
        // Moving between displays: hand the old panel its brightness back
        // before touching the new one.
        restoreBoostedPanel()
        savedBrightness = panel.brightness
        boostedPanel = panel
        panel.brightness = 1.0
    }

    /// Drop `token`'s claim. The panel is restored once nothing holds it.
    /// Safe to call without a matching `boost`.
    func release(token: UUID) {
        holders.remove(token)
        guard holders.isEmpty else { return }
        restoreBoostedPanel()
    }

    private func restoreBoostedPanel() {
        defer {
            savedBrightness = nil
            boostedPanel = nil
        }
        // A nil panel here means it went away while boosted: there is
        // nothing to restore, and the saved value belonged to a display that
        // no longer exists — so it must not leak into the next boost.
        guard let saved = savedBrightness, let panel = boostedPanel else { return }
        panel.brightness = saved
    }
}
#endif
