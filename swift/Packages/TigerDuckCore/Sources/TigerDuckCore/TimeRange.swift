import Foundation

/// A class's start and end as the app, its widgets, the Watch and Live Activities all show them:
/// `HH:mm–HH:mm`, 24-hour, with no spaces.
public enum TimeRange {
    public static func text(_ start: String, _ end: String) -> String {
        "\(start)–\(end)"
    }

    /// Of two minutes after midnight.
    public static func text(from start: Int, to end: Int) -> String {
        text(clock(start), clock(end))
    }

    /// The side of a meeting's times that changed: a start alone stays bare, an end alone reads `–HH:mm`.
    public static func partial(start: String?, end: String?) -> String? {
        switch (start, end) {
        case let (start?, end?): text(start, end)
        case let (start?, nil): start
        case let (nil, end?): "–\(end)"
        case (nil, nil): nil
        }
    }

    /// The range for VoiceOver, with the reader's word for "to": how a screen reader says the en dash
    /// differs by language. Each target's build puts the key in its own main bundle.
    public static func spoken(
        _ start: String, _ end: String,
        localized: (LocalizedStringResource) -> String = { String(localized: $0) }
    ) -> String {
        String(format: localized(LocalizedStringResource("a11y_time_range", bundle: .main)), start, end)
    }

    public static func spoken(
        from start: Int, to end: Int,
        localized: (LocalizedStringResource) -> String = { String(localized: $0) }
    ) -> String {
        spoken(clock(start), clock(end), localized: localized)
    }

    /// The backend parses a class Live Activity's subtitle as `HH:mm - HH:mm` and writes it back so
    /// (https://github.com/tigerduck-app/tigerduck-backend/blob/dev/server/push/class_starts.py).
    public static func liveActivitySubtitle(_ start: String, _ end: String) -> String {
        "\(start) - \(end)"
    }

    public static func times(ofLiveActivitySubtitle subtitle: String) -> (start: String, end: String)? {
        let parts = subtitle.components(separatedBy: " - ")
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    private static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}
