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
/// Brightness is per display but not per view, and `LibraryView` is not a
/// single instance: the Library tab builds one, and Home and More each push
/// their own `LibraryView(embedded: true)` onto their navigation stacks. Two
/// can be alive at once, and with the override state held per view the
/// second one captured the *already boosted* `1.0` as its "pre-boost"
/// value — after which no restore could put the panel back, short of the
/// user finding Control Center.
///
/// Claims are therefore counted per panel. Counting means the boost survives
/// one instance going away while another is still showing a code; keeping a
/// claim *per panel* rather than one global claim means two windows on two
/// displays — which the app allows, it ships with
/// `UIApplicationSupportsMultipleScenes` — do not evict each other. A window
/// that moves between displays hands the one it leaves its brightness back,
/// which is the fold case.
@MainActor
final class LibraryBrightnessCoordinator {
    static let shared = LibraryBrightnessCoordinator()

    /// One panel this coordinator has pinned, and who is asking it to stay
    /// that way.
    private struct Claim {
        /// Weak: a display can be unplugged, or a foldable's panel torn
        /// down, while a claim is still registered. A strong reference would
        /// keep the dead screen allocated and let a later restore write into
        /// an object nobody is looking at.
        weak var panel: (any BrightnessControllable)?
        /// What the panel read before this coordinator touched it. Captured
        /// once, when the claim is opened, so a value we set ourselves can
        /// never be mistaken for the user's.
        let saved: CGFloat
        var holders: Set<UUID>
    }

    /// At most one entry per display, so this is 1–2 elements in practice
    /// and a linear scan by identity beats keying on `ObjectIdentifier`,
    /// which a deallocated screen can hand to its successor.
    private var claims: [Claim] = []

    init() {}

    /// Pin `panel` at full brightness on behalf of `token`.
    ///
    /// Safe to call repeatedly — from `onAppear`, from a scene-phase change,
    /// from a screen move. Calling it with a different panel moves the
    /// token's claim, restoring the previous panel if nothing else holds it.
    func boost(_ panel: any BrightnessControllable, token: UUID) {
        dropDeadPanels()
        // A move between displays: this token no longer speaks for wherever
        // it used to be.
        releaseClaims(of: token, keeping: panel)
        if let index = claims.firstIndex(where: { $0.panel === panel }) {
            claims[index].holders.insert(token)
            return
        }
        claims.append(Claim(panel: panel, saved: panel.brightness, holders: [token]))
        panel.brightness = 1.0
    }

    /// Drop `token`'s claim wherever it is held. A panel is restored once
    /// nothing holds it. Safe to call without a matching `boost`.
    func release(token: UUID) {
        dropDeadPanels()
        releaseClaims(of: token, keeping: nil)
    }

    private func releaseClaims(of token: UUID, keeping survivor: (any BrightnessControllable)?) {
        for index in claims.indices.reversed() {
            if let survivor, claims[index].panel === survivor { continue }
            claims[index].holders.remove(token)
            guard claims[index].holders.isEmpty else { continue }
            claims[index].panel?.brightness = claims[index].saved
            claims.remove(at: index)
        }
    }

    /// A panel that went away while boosted leaves nothing to restore, and
    /// its saved value belonged to a display that no longer exists — so it
    /// must not survive to be written into whatever comes next.
    private func dropDeadPanels() {
        claims.removeAll { $0.panel == nil }
    }
}
#endif
