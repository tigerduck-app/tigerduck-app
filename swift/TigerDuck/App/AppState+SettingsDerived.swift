// Pure derivations over persisted settings — split out of AppState.swift.
//
// Each of these reads a stored, Defaults-backed property that has to stay
// on the class itself and computes something from it; none of them hold
// state of their own, so unlike their backing properties they're free to
// live in an extension. Grouped together because they're small and
// otherwise unrelated: accent color, the announcement-filter department
// set, and the resolved visual-preset policy.

import SwiftUI
import SwiftData
import Defaults
import os

extension AppState {

    var accentColor: Color {
        // Use bitPattern to avoid trapping on a corrupted-defaults negative
        // accentColorHex (Int → UInt conversion crashes on negative values).
        Color(hex: UInt(bitPattern: Int(accentColorHex)))
    }

    /// Saved announcement filter departments (JSON array)
    var savedAnnouncementDepartments: Set<String> {
        get {
            guard let data = Defaults[.savedAnnouncementDepartmentsData],
                  let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return Set(arr)
        }
        set {
            do {
                let data = try JSONEncoder().encode(Array(newValue))
                Defaults[.savedAnnouncementDepartmentsData] = data
            } catch {
                AppLogger.captureError(error, context: ["phase": "savedAnnouncementDepartments.encode"])
            }
        }
    }

    /// Resolved presentation policy for the current preset. Views read
    /// from this instead of switching on ``visualPreset`` directly, so
    /// adding new presets stays contained to ``VisualStylePolicy``.
    var visualStylePolicy: VisualStylePolicy {
        VisualStylePolicy(preset: visualPreset)
    }

}
