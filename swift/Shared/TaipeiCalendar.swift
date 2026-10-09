import Foundation

/// Single source of the Taipei-pinned time math for the iOS and watch apps.
/// NTUST's class table, ICS feed and Moodle deadlines use Taipei wall time, so
/// every "what day is it / is class now?" decision must use this calendar.
/// `Calendar.current` follows the device and would be up to a day off abroad.
///
/// The phone app re-exports these as `AppConstants.taipeiTimeZone` and
/// `AppConstants.taipeiCalendar`. The widget extension keeps its own copy,
/// `WidgetTaipei`, because `Shared/` is not in its target membership.
public enum SharedTaipei {
    public static let timeZone: TimeZone = TimeZone(identifier: "Asia/Taipei") ?? .current

    public static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }()
}
