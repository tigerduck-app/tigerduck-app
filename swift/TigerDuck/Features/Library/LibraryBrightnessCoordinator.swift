#if os(iOS)
import UIKit

struct WeakScreen: Equatable {
    weak var screen: UIScreen?

    init(_ screen: UIScreen? = nil) {
        self.screen = screen
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.screen === rhs.screen
    }
}

protocol BrightnessControllable: AnyObject {
    var brightness: CGFloat { get set }
}

extension UIScreen: BrightnessControllable {}

@MainActor
final class LibraryBrightnessCoordinator {
    static let shared = LibraryBrightnessCoordinator()

    private struct Claim {
        weak var panel: (any BrightnessControllable)?
        let saved: CGFloat
        var holders: Set<UUID>
    }

    private var claims: [Claim] = []

    init() {}

    func boost(_ panel: any BrightnessControllable, token: UUID) {
        dropDeadPanels()
        releaseClaims(of: token, keeping: panel)
        if let index = claims.firstIndex(where: { $0.panel === panel }) {
            claims[index].holders.insert(token)
            return
        }
        claims.append(Claim(panel: panel, saved: panel.brightness, holders: [token]))
        panel.brightness = 1.0
    }

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

    private func dropDeadPanels() {
        claims.removeAll { $0.panel == nil }
    }
}
#endif
