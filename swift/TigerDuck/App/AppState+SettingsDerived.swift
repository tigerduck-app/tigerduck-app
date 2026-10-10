// Pure derivations over Defaults-backed stored properties, which must stay on the
// class. These hold no state, so they can live in an extension. They are small and
// otherwise unrelated: accent color, announcement-filter departments, visual preset.

import SwiftUI
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
