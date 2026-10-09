import Foundation
import os
import SwiftUI

/// Multiplier on the course-name font in the class table (`TimetableGridView`)
/// and the iOS and iPadOS home-screen widgets (Next Class, Today, Week); 1.0 is
/// the size with no user override. ``CourseCardFontScaleStore`` keeps it in the
/// App Group so the widgets read what the app writes; a change reloads them,
/// debounced. With ``baselineMultiplier``, 0.6…1.2× renders at 0.84…1.68× of the
/// cell font: smaller is unreadable, larger overflows the cell before
/// `minimumScaleFactor` rescues it. Mac and Watch surfaces do not apply it.
/// See docs/decisions/0004-course-font-scale-ios-only.md.
// `nonisolated`: every member is a pure constant or function. Otherwise the
// project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` isolates the enum, and the
// `nonisolated` store below and the widget extension, built without it, can't read it.
nonisolated enum CourseCardFontScale {
    /// Inclusive bounds the slider operates over. Out-of-range stored
    /// values are clamped on read so a manually-edited UserDefaults value
    /// can never escape this range.
    static let minimum: Double = 0.6
    static let maximum: Double = 1.2
    /// Slider snaps to 0.05× ticks so the displayed `1.20×` value is
    /// reproducible — a continuous CGFloat would let the user land on
    /// 1.196… which reads as 1.20× but compares unequal across launches.
    static let step: Double = 0.05
    /// Baseline the slider shows as 1.00×.
    static let `default`: Double = 1.0
    /// The pre-feature 1.00× rendered too small, so what used to be the
    /// 1.40× setting is now the 1.00× default. Every render site multiplies
    /// this in via ``renderScale(_:)``; the stored/user-facing value stays
    /// in slider units.
    static let baselineMultiplier: Double = 1.4

    /// Multiplier to apply to a base font size for a stored slider value.
    static func renderScale(_ scale: Double) -> Double {
        normalize(scale) * baselineMultiplier
    }

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

/// App Group reader and writer for the course-card font scale: the main app
/// reads and writes it, the widget extension reads it at render time.
///
/// An unreachable App Group (a container-URL check, see ``isAppGroupAvailable(_:)``)
/// asserts in DEBUG, as `WidgetSnapshotStore` does, so an empty
/// `com.apple.security.application-groups` entitlement cannot ship unnoticed.
/// Release falls back to `.standard` and logs an error so the app still launches,
/// though the app and the widget extension then persist to separate stores.
nonisolated final class CourseCardFontScaleStore {
    /// The shipping App Group. Named so the reachability requirement below
    /// can tell it apart from an injected test suite.
    static let appGroupIdentifier = "group.org.ntust.app.TigerDuck"
    static let storageKey = "courseCardFontScaleV2"
    /// Pre-rebase key. Its values were in the old units (1.4 = today's
    /// 1.0), so `read()` converts once and moves the value to `storageKey`.
    static let legacyStorageKey = "courseCardFontScale"

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "FontScale")

    /// Whether this process can reach the shared App Group.
    ///
    /// `UserDefaults(suiteName:)` cannot tell: it returns nil only for reserved
    /// names and hands back a process-local store for a group the process has no
    /// entitlement for. See `WidgetSnapshotStore.isAppGroupAvailable(_:)` for the
    /// full rationale. The check is duplicated because the two files sit in
    /// different synchronized folders, and sharing it would need a new
    /// target-membership exception in the project file.
    static func isAppGroupAvailable(_ identifier: String) -> Bool {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        ) != nil
    }

    init(appGroupIdentifier: String = CourseCardFontScaleStore.appGroupIdentifier) {
        // Only the shipping App Group has to be *reachable*. An injected
        // identifier is a test seam pointing at an ordinary UserDefaults
        // suite, which has no container and never will.
        let requiresSharedContainer = appGroupIdentifier == Self.appGroupIdentifier
        if !requiresSharedContainer || Self.isAppGroupAvailable(appGroupIdentifier),
           let suite = UserDefaults(suiteName: appGroupIdentifier) {
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
        // `double(forKey:)` returns 0.0 for a missing key, which would clamp to the
        // minimum. `object(forKey:)` detects the unset case first, so a user who never
        // set a scale gets the default (1.0).
        guard defaults.object(forKey: Self.storageKey) != nil else {
            return migrateLegacyValue() ?? CourseCardFontScale.default
        }
        let raw = defaults.double(forKey: Self.storageKey)
        return CourseCardFontScale.normalize(raw)
    }

    /// One-shot: a value stored before the baseline rebase is divided by
    /// `baselineMultiplier` so the user keeps the size they had chosen.
    private func migrateLegacyValue() -> Double? {
        guard defaults.object(forKey: Self.legacyStorageKey) != nil else { return nil }
        let migrated = CourseCardFontScale.normalize(
            defaults.double(forKey: Self.legacyStorageKey) / CourseCardFontScale.baselineMultiplier
        )
        defaults.set(migrated, forKey: Self.storageKey)
        defaults.removeObject(forKey: Self.legacyStorageKey)
        return migrated
    }

    func write(_ scale: Double) {
        defaults.set(CourseCardFontScale.normalize(scale), forKey: Self.storageKey)
    }
}
