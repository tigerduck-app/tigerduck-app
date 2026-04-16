import SwiftUI

/// Centralizes Live Activity / reminder related preferences so `AppState`
/// does not keep accumulating unrelated toggles.
///
/// Defaults match the spec's recommendations:
/// - `assignmentReminderOffsets`: all 11 offsets selected
/// - `isLiveActivityEnabled`: true
/// - `assignmentLiveActivityLeadTime`: 8 hours (also the spec cap)
/// - `classPreparingLeadTime`: 15 minutes
/// - All scenario toggles on
@Observable
final class LiveActivityPreferencesStore {
    static let defaultOffsets: Set<AssignmentReminderOffset> = Set(AssignmentReminderOffset.allCases)
    static let defaultAssignmentLeadTime: TimeInterval = 8 * 3600
    static let defaultClassPreparingLeadTime: TimeInterval = 15 * 60
    /// Spec invariant: Live Activity lead time must not exceed 8 hours to fit the activity lifecycle.
    static let maximumAssignmentLeadTime: TimeInterval = 8 * 3600

    var assignmentReminderOffsets: Set<AssignmentReminderOffset> {
        didSet { persistOffsets(); notifyChange() }
    }
    var isLiveActivityEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                isLiveActivityEnabled,
                forKey: AppConstants.UserDefaultsKeys.isLiveActivityEnabled
            )
            notifyChange()
        }
    }
    var assignmentLiveActivityLeadTime: TimeInterval {
        didSet {
            UserDefaults.standard.set(
                assignmentLiveActivityLeadTime,
                forKey: AppConstants.UserDefaultsKeys.assignmentLiveActivityLeadTime
            )
            notifyChange()
        }
    }
    var classPreparingLeadTime: TimeInterval {
        didSet {
            UserDefaults.standard.set(
                classPreparingLeadTime,
                forKey: AppConstants.UserDefaultsKeys.classPreparingLeadTime
            )
            notifyChange()
        }
    }
    var showAssignmentScenario: Bool {
        didSet {
            UserDefaults.standard.set(
                showAssignmentScenario,
                forKey: AppConstants.UserDefaultsKeys.showAssignmentScenario
            )
            notifyChange()
        }
    }
    var showClassPreparingScenario: Bool {
        didSet {
            UserDefaults.standard.set(
                showClassPreparingScenario,
                forKey: AppConstants.UserDefaultsKeys.showClassPreparingScenario
            )
            notifyChange()
        }
    }
    var showInClassScenario: Bool {
        didSet {
            UserDefaults.standard.set(
                showInClassScenario,
                forKey: AppConstants.UserDefaultsKeys.showInClassScenario
            )
            notifyChange()
        }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: AppConstants.UserDefaultsKeys.assignmentReminderOffsets),
           let raws = try? JSONDecoder().decode([String].self, from: data) {
            assignmentReminderOffsets = Set(raws.compactMap { AssignmentReminderOffset(rawValue: $0) })
        } else {
            assignmentReminderOffsets = Self.defaultOffsets
        }

        isLiveActivityEnabled = UserDefaults.standard.object(
            forKey: AppConstants.UserDefaultsKeys.isLiveActivityEnabled
        ) as? Bool ?? true

        let rawAssignmentLead = UserDefaults.standard.double(
            forKey: AppConstants.UserDefaultsKeys.assignmentLiveActivityLeadTime
        )
        assignmentLiveActivityLeadTime = rawAssignmentLead > 0 ? rawAssignmentLead : Self.defaultAssignmentLeadTime

        let rawClassLead = UserDefaults.standard.double(
            forKey: AppConstants.UserDefaultsKeys.classPreparingLeadTime
        )
        classPreparingLeadTime = rawClassLead > 0 ? rawClassLead : Self.defaultClassPreparingLeadTime

        showAssignmentScenario = UserDefaults.standard.object(
            forKey: AppConstants.UserDefaultsKeys.showAssignmentScenario
        ) as? Bool ?? true
        showClassPreparingScenario = UserDefaults.standard.object(
            forKey: AppConstants.UserDefaultsKeys.showClassPreparingScenario
        ) as? Bool ?? true
        showInClassScenario = UserDefaults.standard.object(
            forKey: AppConstants.UserDefaultsKeys.showInClassScenario
        ) as? Bool ?? true
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
            UserDefaults.standard.set(data, forKey: AppConstants.UserDefaultsKeys.assignmentReminderOffsets)
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
