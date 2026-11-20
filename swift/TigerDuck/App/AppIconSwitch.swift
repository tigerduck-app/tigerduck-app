import Defaults
import UIKit

@MainActor
protocol AlternateIconHost: AnyObject {
    var supportsAlternateIcons: Bool { get }
    var alternateIconName: String? { get }
    func setAlternateIconName(_ alternateIconName: String?) async throws
}

extension UIApplication: AlternateIconHost {}

/// Shows the app icon stored in `Defaults[.appIcon]`. The choice is written only once the system
/// shows it, so the picker never marks an icon the Home Screen does not have.
@MainActor
enum AppIconSwitch {
    /// What `setAlternateIconName` takes for a choice: `nil` is the primary icon.
    static func alternateName(for choice: AppIcon?, primary: AppIcon?) -> String? {
        guard let choice, choice != primary else { return nil }
        return choice.rawValue
    }

    static func choose(
        _ choice: AppIcon?, host: any AlternateIconHost = UIApplication.shared, primary: AppIcon? = AppIcon.primary()
    ) async {
        if await show(choice, host: host, primary: primary) {
            Defaults[.appIcon] = choice
        }
    }

    /// An update can turn a pinned icon into the primary or the primary into an alternate, while
    /// iOS keeps the alternate name it was last given; each return to the app sets it again.
    static func reconcile(host: any AlternateIconHost = UIApplication.shared, primary: AppIcon? = AppIcon.primary()) async {
        _ = await show(Defaults[.appIcon], host: host, primary: primary)
    }

    /// iOS's alert for a new icon can make the scene active again before the change returns, and
    /// a second change then could undo the first.
    private static var isChanging = false

    private static func show(_ choice: AppIcon?, host: any AlternateIconHost, primary: AppIcon?) async -> Bool {
        let name = alternateName(for: choice, primary: primary)
        guard host.alternateIconName != name else { return true }
        guard host.supportsAlternateIcons, !isChanging else { return false }
        isChanging = true
        defer { isChanging = false }
        do {
            try await host.setAlternateIconName(name)
            return true
        } catch {
            AppLogger.captureError(error, context: ["phase": "appIcon.set"])
            return false
        }
    }
}
