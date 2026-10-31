import Defaults
import Foundation

/// A custom accent saved before the light cards were checked can read below 3:1 on them. The
/// saved value moves once to its readable shade, so the widgets and the Watch get it too.
enum CustomAccentContrastMigration {
    private static let doneKey = "CustomAccentContrastMigration.v1.done"

    @discardableResult
    static func runIfNeeded() -> Bool {
        guard !AppUserDefaults.standard.bool(forKey: doneKey) else { return false }
        defer { AppUserDefaults.standard.set(true, forKey: doneKey) }
        let saved = Defaults[.accentColorHex] & 0xFFFFFF
        guard !AppState.themeColors.contains(where: { $0.hex == saved }) else { return false }
        let readable = AccentContrast.readable(saved)
        guard readable != saved else { return false }
        Defaults[.accentColorHex] = readable
        return true
    }
}
