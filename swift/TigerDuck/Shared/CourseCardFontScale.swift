import Foundation
import os
import SwiftUI

nonisolated enum CourseCardFontScale {
    static let minimum: Double = 0.6
    static let maximum: Double = 1.2
    static let step: Double = 0.05
    static let `default`: Double = 1.0
    static let baselineMultiplier: Double = 1.4

    static func renderScale(_ scale: Double) -> Double {
        normalize(scale) * baselineMultiplier
    }

    static func normalize(_ value: Double) -> Double {
        let clamped = min(max(value, minimum), maximum)
        let stepped = (clamped / step).rounded() * step
        return min(max(stepped, minimum), maximum)
    }
}

nonisolated final class CourseCardFontScaleStore {
    static let appGroupIdentifier = "group.org.ntust.app.TigerDuck"
    static let storageKey = "courseCardFontScaleV2"
    static let legacyStorageKey = "courseCardFontScale"

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "FontScale")

    /// `UserDefaults(suiteName:)` cannot tell: it returns nil only for reserved
    /// names and hands back a process-local store for a group the process has no
    /// entitlement for. See `WidgetSnapshotStore.isAppGroupAvailable(_:)` for the
    static func isAppGroupAvailable(_ identifier: String) -> Bool {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        ) != nil
    }

    init(appGroupIdentifier: String = CourseCardFontScaleStore.appGroupIdentifier) {
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
