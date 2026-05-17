import Foundation

/// Widget-extension-local mirror of `SharedTaipei`. The `Shared/` folder
/// is not part of the widget extension's target membership, so this
/// duplicates the two constants the widget needs to keep "what day is
/// it / is class now?" math aligned with the iOS app (which pins to
/// Taipei via `AppConstants.taipeiCalendar`).
///
/// Keep in sync with `SharedTaipei`.
enum WidgetTaipei {
    static let timeZone: TimeZone = TimeZone(identifier: "Asia/Taipei") ?? .current

    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }()
}
