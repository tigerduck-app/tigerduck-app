import Foundation
import os
import SwiftUI

/// Multiplier applied to the course-name font size in the class table
/// (`TimetableGridView`) and the course-name labels inside the iOS /
/// iPadOS home-screen widgets (Next Class, Today, Week). 1.0 = the
/// baseline size every cell would render at without the user override.
///
/// Scope — Mac is intentionally excluded: `MacClassTableView` keeps its
/// fixed `.callout.weight(.semibold)` baseline and `MacSettingsScene`
/// exposes no slider, so this scale is a no-op for the Mac app and any
/// Mac-native widgets. The Mac surfaces are sized for a desktop window
/// and a per-app text-size override is redundant there — users who
/// want larger text use the system-wide "Larger Text" accessibility
/// setting instead. See `.greptile/rules.md` ("Course-name font scale
/// is iOS/iPadOS only").
///
/// Scope — Watch is also excluded: the watchOS widgets use a separate
/// App Group (`group.org.ntust.app.TigerDuck.watch`) and are NOT wired
/// up to this scale. Watch font sizing is governed by Apple's
/// complication ramps and a sync channel would need to be added before
/// the user-facing toggle could honor Watch surfaces.
///
/// Persisted via ``CourseCardFontScaleStore`` in the App Group
/// `UserDefaults` suite so the widget extension can read the same value
/// the main app writes. Changing the value in the main app triggers a
/// debounced widget timeline reload (see `AppState.courseCardFontScale`
/// and `WidgetReloadCoordinator`) so widgets pick it up on their next
/// render.
///
/// The scale is intentionally narrow (0.8…1.6×): below 0.8 the names
/// become unreadable inside the timetable cells, above 1.6× they overflow
/// the cell before `minimumScaleFactor` rescues them — at which point the
/// user is fighting the layout, not customizing it.
// `nonisolated` because every member is a pure constant or pure function
// (no actor state). Without it, the project's `SWIFT_DEFAULT_ACTOR_ISOLATION
// = MainActor` makes the enum MainActor-isolated, which then can't be read
// from the `nonisolated` `CourseCardFontScaleStore` below (or the widget
// extension, which compiles without the MainActor default).
nonisolated enum CourseCardFontScale {
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
/// (read-only at view body render time).
///
/// In DEBUG we crash hard if the suite is unavailable so an empty
/// `com.apple.security.application-groups` regression cannot ship
/// silently — same protocol as `WidgetSnapshotStore`. In release we
/// still fall back to `.standard` with a loud error so a user with a
/// provisioning hiccup still launches, but the divergence is no longer
/// invisible (main app vs. widget extension would otherwise persist to
/// different process-local stores).
nonisolated final class CourseCardFontScaleStore {
    static let storageKey = "courseCardFontScale"

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "FontScale")

    init(appGroupIdentifier: String = "group.org.ntust.app.TigerDuck") {
        if let suite = UserDefaults(suiteName: appGroupIdentifier) {
            self.defaults = suite
        } else {
            assertionFailure(
                "App Group suite '\(appGroupIdentifier)' unavailable — verify `com.apple.security.application-groups` is populated in BOTH the TigerDuck app AND TigerDuckWidgets extension entitlements and that the App Group capability is enabled on each target."
            )
            self.defaults = .standard
            logger.error("App Group suite '\(appGroupIdentifier, privacy: .public)' unavailable — course-name font scale will diverge between main app and widget process")
        }
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
