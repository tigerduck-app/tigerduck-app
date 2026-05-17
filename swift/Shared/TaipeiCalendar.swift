import Foundation

/// Single source of truth for the Taiwan-pinned time math shared between
/// the iOS app and the watch app. NTUST's class table, ICS feed, and
/// Moodle deadlines are all authored in Taipei wall time, so every
/// "what day is it / is class now?" decision must read against this
/// calendar — not `Calendar.current`, which follows the device locale
/// and would shift weekday math by up to a full day when the student is
/// traveling.
///
/// The phone-app surface re-exports these constants as
/// `AppConstants.taipeiTimeZone` / `AppConstants.taipeiCalendar`. The
/// widget extension keeps its own local copy (`WidgetTaipei`) because
/// `Shared/` is not in its target membership.
public enum SharedTaipei {
    public static let timeZone: TimeZone = TimeZone(identifier: "Asia/Taipei") ?? .current

    public static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }()
}
