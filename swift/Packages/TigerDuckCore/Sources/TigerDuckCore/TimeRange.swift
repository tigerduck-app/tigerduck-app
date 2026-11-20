import Foundation

public enum TimeRange {
    public static func text(_ start: String, _ end: String) -> String {
        "\(start)–\(end)"
    }

    /// Of two minutes after midnight.
    public static func text(from start: Int, to end: Int) -> String {
        text(clock(start), clock(end))
    }

    public static func partial(start: String?, end: String?) -> String? {
        switch (start, end) {
        case let (start?, end?): text(start, end)
        case let (start?, nil): start
        case let (nil, end?): "–\(end)"
        case (nil, nil): nil
        }
    }

    /// A screen reader does not reliably read an en dash between two times as "to", so VoiceOver gets
    /// the range in words. Each target's build puts the key in its own main bundle, not the package's.
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
        guard parts.count == 2, parts.allSatisfy({ ClassTimeline.minutes(of: $0) != nil }) else { return nil }
        return (parts[0], parts[1])
    }

    private static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}
