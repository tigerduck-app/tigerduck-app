import Foundation
import SwiftUI

/// Multiplier applied to the course-name font size in the class table
/// (`TimetableGridView`) and the course-name labels inside the home-screen
/// widgets (Next Class, Today, Week). 1.0 = the baseline size every cell
/// would render at without the user override.
///
/// Persisted via ``CourseCardFontScaleStore`` in the App Group
/// `UserDefaults` suite so the widget extension can read the same value
/// the main app writes. Changing the value in the main app triggers
/// `WidgetCenter.shared.reloadAllTimelines()` so widgets pick it up on
/// their next render.
///
/// The scale is intentionally narrow (0.8…1.6×): below 0.8 the names
/// become unreadable inside the timetable cells, above 1.6× they overflow
/// the cell before `minimumScaleFactor` rescues them — at which point the
/// user is fighting the layout, not customizing it.
enum CourseCardFontScale {
    /// Inclusive bounds the slider operates over. Out-of-range stored
    /// values are clamped on read so a manually-edited UserDefaults value
    /// can never escape this range.
    static let minimum: Double = 0.8
    static let maximum: Double = 1.6
    /// Slider snaps to 0.05× ticks so the displayed `1.20×` value is
    /// reproducible — a continuous CGFloat would let the user land on
    /// 1.196… which reads as 1.20× but compares unequal across launches.
    static let step: Double = 0.05
    /// Baseline: no scaling, matches the pre-feature rendering exactly.
    static let `default`: Double = 1.0

    /// Clamp + snap to the nearest `step` so the slider can persist its
    /// continuous CGFloat as a clean stepped value.
    static func normalize(_ value: Double) -> Double {
        let clamped = min(max(value, minimum), maximum)
        let stepped = (clamped / step).rounded() * step
        // Re-clamp after rounding in case the snap pushed past a bound
        // (only theoretically possible if `step` doesn't divide the
        // range cleanly, but defensive against future tuning).
        return min(max(stepped, minimum), maximum)
    }
}

/// App-group-backed reader/writer for the course-card font scale. Used
/// by both the main app (read + write) and the widget extension
/// (read-only at view body render time). Falls back to `.standard` if
/// the App Group suite is missing so a provisioning hiccup degrades
/// gracefully instead of crashing.
nonisolated final class CourseCardFontScaleStore {
    static let storageKey = "courseCardFontScale"

    private let defaults: UserDefaults

    init(appGroupIdentifier: String = "group.org.ntust.app.TigerDuck") {
        self.defaults = UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    /// Read the user's scale, falling back to `1.0` when unset. Always
    /// returns a normalized value so callers can use it directly without
    /// re-normalizing at every render site.
    func read() -> Double {
        // `double(forKey:)` returns `0.0` when the key is missing, which
        // is a valid storage value but indistinguishable from "unset".
        // Use `object(forKey:)` first to detect the unset case explicitly
        // so a never-set user gets the actual default (1.0) instead of a
        // clamped 0.8.
        guard defaults.object(forKey: Self.storageKey) != nil else {
            return CourseCardFontScale.default
        }
        let raw = defaults.double(forKey: Self.storageKey)
        return CourseCardFontScale.normalize(raw)
    }

    func write(_ scale: Double) {
        defaults.set(CourseCardFontScale.normalize(scale), forKey: Self.storageKey)
    }
}
