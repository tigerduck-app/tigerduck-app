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
    nonisolated static let defaultOffsets: Set<AssignmentReminderOffset> = [.hr48, .hr24, .hr8, .hr2, .hr1, .min30]
    nonisolated static let defaultAssignmentLeadTime: TimeInterval = 8 * 3600
    nonisolated static let defaultClassPreparingLeadTime: TimeInterval = 60 * 60
    nonisolated static let minimumClassPreparingLeadTime: TimeInterval = 5 * 60
    nonisolated static let maximumClassPreparingLeadTime: TimeInterval = 4 * 3600
    /// Spec invariant: Live Activity lead time must not exceed 8 hours to fit the activity lifecycle.
    nonisolated static let maximumAssignmentLeadTime: TimeInterval = 8 * 3600

    var assignmentReminderOffsets: Set<AssignmentReminderOffset> {
        didSet {
            persistOffsets()
            guard !isApplyingRemoteUpdate else { return }
            notifyChange()
        }
    }
    /// Master switch for assignment due reminders. When off, the scheduler is
    /// fed an empty offset set, which cancels all pending reminders. Mirrors
    /// Android's `notifyAssignments`.
    var isAssignmentReminderEnabled: Bool {
        didSet {
            Defaults[.isAssignmentReminderEnabled] = isAssignmentReminderEnabled
            guard !isApplyingRemoteUpdate else { return }
            notifyChange()
        }
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
            guard !isApplyingRemoteUpdate else { return }
            notifyChange()
        }
    }
    var classPreparingLeadTime: TimeInterval {
        didSet {
            Defaults[.classPreparingLeadTime] = classPreparingLeadTime
            guard !isApplyingRemoteUpdate else { return }
            notifyChange()
        }
    }
    var showAssignmentScenario: Bool {
        didSet {
            Defaults[.showAssignmentScenario] = showAssignmentScenario
            guard !isApplyingRemoteUpdate else { return }
            notifyChange()
        }
    }
    var showClassPreparingScenario: Bool {
        didSet {
            Defaults[.showClassPreparingScenario] = showClassPreparingScenario
            guard !isApplyingRemoteUpdate else { return }
            notifyChange()
        }
    }
    var showInClassScenario: Bool {
        didSet {
            Defaults[.showInClassScenario] = showInClassScenario
            guard !isApplyingRemoteUpdate else { return }
            notifyChange()
        }
    }

    /// Set while ``applyFromNotificationSettingsDocument`` is assigning
    /// properties on behalf of a pull from the backend. Suppresses
    /// ``notifyChange()`` on the affected properties' `didSet` so applying
    /// a value that just arrived FROM the server does not immediately
    /// re-queue it as an outgoing push of the same data — see
    /// `AppState+NotificationSettings.swift`.
    private var isApplyingRemoteUpdate = false

    init() {
        if let data = Defaults[.assignmentReminderOffsetsData],
           let raws = try? JSONDecoder().decode([String].self, from: data) {
            assignmentReminderOffsets = Set(raws.compactMap { AssignmentReminderOffset(rawValue: $0) })
        } else {
            assignmentReminderOffsets = Self.defaultOffsets
        }

        isAssignmentReminderEnabled = Defaults[.isAssignmentReminderEnabled]
        isLiveActivityEnabled = Defaults[.isLiveActivityEnabled]

        // Clamp on load: a value persisted by an older build that used a
        // larger maximum would otherwise stay above the current cap until
        // the user touched the slider, silently breaking the invariant.
        let rawAssignmentLead = Defaults[.assignmentLiveActivityLeadTime]
        let resolvedAssignmentLead = rawAssignmentLead > 0 ? rawAssignmentLead : Self.defaultAssignmentLeadTime
        assignmentLiveActivityLeadTime = min(resolvedAssignmentLead, Self.maximumAssignmentLeadTime)

        let rawClassLead = Defaults[.classPreparingLeadTime]
        let resolvedClassLead = rawClassLead > 0 ? rawClassLead : Self.defaultClassPreparingLeadTime
        classPreparingLeadTime = min(resolvedClassLead, Self.maximumClassPreparingLeadTime)

        showAssignmentScenario = Defaults[.showAssignmentScenario]
        showClassPreparingScenario = Defaults[.showClassPreparingScenario]
        showInClassScenario = Defaults[.showInClassScenario]
    }

    /// Reset Live Activity display defaults. Exposed for settings UI.
    ///
    /// Deliberately does NOT touch assignment-reminder state
    /// (`isAssignmentReminderEnabled` / `assignmentReminderOffsets`): those
    /// live on the separate Assignment Reminder settings screen, and resetting
    /// them here would silently re-enable reminders the user had turned off.
    func resetToDefaults() {
        isLiveActivityEnabled = true
        assignmentLiveActivityLeadTime = Self.defaultAssignmentLeadTime
        classPreparingLeadTime = Self.defaultClassPreparingLeadTime
        showAssignmentScenario = true
        showClassPreparingScenario = true
        showInClassScenario = true
    }

    /// Applies the subset of preferences carried by the `notification`
    /// settings document's `assignments` and `live_activity` sections
    /// (`AppState.pullNotificationSettings()`). Persists exactly like a
    /// local edit — each property's normal `didSet` still runs and writes
    /// through to `Defaults` — but does not post
    /// `liveActivityPreferencesDidChange`: these values just arrived FROM
    /// the server, so treating the pull as a fresh local edit would
    /// immediately queue a redundant push of the same data straight back
    /// to the document it came from.
    ///
    /// Clamps the two lead times the same way `init()` does: a value from
    /// another platform (or a future server-side default) is not bound by
    /// this build's slider ranges and could exceed today's caps.
    func applyFromNotificationSettingsDocument(
        isAssignmentReminderEnabled: Bool,
        assignmentReminderOffsets: Set<AssignmentReminderOffset>,
        showClassPreparingScenario: Bool,
        showInClassScenario: Bool,
        showAssignmentScenario: Bool,
        classPreparingLeadTime: TimeInterval,
        assignmentLiveActivityLeadTime: TimeInterval
    ) {
        isApplyingRemoteUpdate = true
        defer { isApplyingRemoteUpdate = false }

        self.isAssignmentReminderEnabled = isAssignmentReminderEnabled
        self.assignmentReminderOffsets = assignmentReminderOffsets

        self.showClassPreparingScenario = showClassPreparingScenario
        self.showInClassScenario = showInClassScenario
        self.showAssignmentScenario = showAssignmentScenario

        let resolvedClassLead = classPreparingLeadTime > 0 ? classPreparingLeadTime : Self.defaultClassPreparingLeadTime
        self.classPreparingLeadTime = min(max(resolvedClassLead, Self.minimumClassPreparingLeadTime), Self.maximumClassPreparingLeadTime)

        let resolvedAssignmentLead = assignmentLiveActivityLeadTime > 0 ? assignmentLiveActivityLeadTime : Self.defaultAssignmentLeadTime
        self.assignmentLiveActivityLeadTime = min(resolvedAssignmentLead, Self.maximumAssignmentLeadTime)
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
