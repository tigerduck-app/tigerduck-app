import SwiftUI
import Defaults

/// Centralizes Live Activity / reminder related preferences so `AppState`
/// does not keep accumulating unrelated toggles.
///
/// Defaults:
/// - `assignmentReminderOffsets`: 6 high-signal offsets (48h/24h/8h/2h/1h/30m)
///   — sized so 10 concurrent unfinished assignments still fit under the
///   scheduler's 60-pending cap without silent drops. Users can opt into
///   denser coverage in Settings.
/// - `isLiveActivityEnabled`: true
/// - `assignmentLiveActivityLeadTime`: 8 hours (also the spec cap)
/// - `classPreparingLeadTime`: 1 hour (range 5 minutes ... 4 hours)
/// - All scenario toggles on
@Observable
final class LiveActivityPreferencesStore {
    static let defaultOffsets: Set<AssignmentReminderOffset> = [.hr48, .hr24, .hr8, .hr2, .hr1, .min30]
    static let defaultAssignmentLeadTime: TimeInterval = 8 * 3600
    static let defaultClassPreparingLeadTime: TimeInterval = 60 * 60
    static let minimumClassPreparingLeadTime: TimeInterval = 5 * 60
    static let maximumClassPreparingLeadTime: TimeInterval = 4 * 3600
    /// Spec invariant: Live Activity lead time must not exceed 8 hours to fit the activity lifecycle.
    static let maximumAssignmentLeadTime: TimeInterval = 8 * 3600

    var assignmentReminderOffsets: Set<AssignmentReminderOffset> {
        didSet { persistOffsets(); notifyChange() }
    }
    var isLiveActivityEnabled: Bool {
        didSet {
            Defaults[.isLiveActivityEnabled] = isLiveActivityEnabled
            notifyChange()
        }
    }
    var assignmentLiveActivityLeadTime: TimeInterval {
        didSet {
            Defaults[.assignmentLiveActivityLeadTime] = assignmentLiveActivityLeadTime
            notifyChange()
        }
    }
    var classPreparingLeadTime: TimeInterval {
        didSet {
            Defaults[.classPreparingLeadTime] = classPreparingLeadTime
            notifyChange()
        }
    }
    var showAssignmentScenario: Bool {
        didSet {
            Defaults[.showAssignmentScenario] = showAssignmentScenario
            notifyChange()
        }
    }
    var showClassPreparingScenario: Bool {
        didSet {
            Defaults[.showClassPreparingScenario] = showClassPreparingScenario
            notifyChange()
        }
    }
    var showInClassScenario: Bool {
        didSet {
            Defaults[.showInClassScenario] = showInClassScenario
            notifyChange()
        }
    }

    init() {
        if let data = Defaults[.assignmentReminderOffsetsData],
           let raws = try? JSONDecoder().decode([String].self, from: data) {
            assignmentReminderOffsets = Set(raws.compactMap { AssignmentReminderOffset(rawValue: $0) })
        } else {
            assignmentReminderOffsets = Self.defaultOffsets
        }

        isLiveActivityEnabled = Defaults[.isLiveActivityEnabled]

        let rawAssignmentLead = Defaults[.assignmentLiveActivityLeadTime]
        assignmentLiveActivityLeadTime = rawAssignmentLead > 0 ? rawAssignmentLead : Self.defaultAssignmentLeadTime

        let rawClassLead = Defaults[.classPreparingLeadTime]
        classPreparingLeadTime = rawClassLead > 0 ? rawClassLead : Self.defaultClassPreparingLeadTime

        showAssignmentScenario = Defaults[.showAssignmentScenario]
        showClassPreparingScenario = Defaults[.showClassPreparingScenario]
        showInClassScenario = Defaults[.showInClassScenario]
    }

    /// Reset everything to defaults. Exposed for settings UI.
    func resetToDefaults() {
        assignmentReminderOffsets = Self.defaultOffsets
        isLiveActivityEnabled = true
        assignmentLiveActivityLeadTime = Self.defaultAssignmentLeadTime
        classPreparingLeadTime = Self.defaultClassPreparingLeadTime
        showAssignmentScenario = true
        showClassPreparingScenario = true
        showInClassScenario = true
    }

    private func persistOffsets() {
        let raws = assignmentReminderOffsets.map(\.rawValue).sorted()
        if let data = try? JSONEncoder().encode(raws) {
            Defaults[.assignmentReminderOffsetsData] = data
        } else {
            Defaults[.assignmentReminderOffsetsData] = nil
        }
    }

    /// Broadcasts that one or more preferences changed. AppState debounces
    /// the resulting refresh so rapid changes (e.g. dragging a slider) do
    /// not trigger many back-to-back Live Activity / notification reschedules.
    private func notifyChange() {
        NotificationCenter.default.post(
            name: AppConstants.liveActivityPreferencesDidChange,
            object: nil
        )
    }
}
