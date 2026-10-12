import SwiftUI
import Defaults

/// Whether Live Activity may run now: the user's `isLiveActivityEnabled` switch
/// and `cloudSyncEnabled` ("Sync course information"). Sync off makes Live
/// Activity unavailable, as `sync_courses_footer_platform_note` tells users.
/// Every reader calls this instead of re-deriving it: the scenario resolver, the
/// schedule upload, and the coordinator before keeping any activity. Both inputs
/// are parameters, as `AppState` owns `cloudSyncEnabled`. It writes neither: a
/// stored `false` would lose the user's switch when sync comes back on.
/// See docs/decisions/0012-live-activity-requires-course-sync.md.
func effectiveLiveActivityEnabled(isLiveActivityEnabled: Bool, cloudSyncEnabled: Bool) -> Bool {
    isLiveActivityEnabled && cloudSyncEnabled
}

/// Centralizes Live Activity and reminder preferences so `AppState` does not
/// keep accumulating unrelated toggles.
///
/// Defaults:
/// - `assignmentReminderOffsets`: the high-signal 48h/24h/8h/2h/1h/30m; denser is opt-in.
/// - `isLiveActivityEnabled` and all scenario toggles: on.
/// - `assignmentLiveActivityLeadTime`: 8 hours, also the maximum.
/// - `classPreparingLeadTime`: 1 hour (range 5 minutes ... 4 hours).
@Observable
final class LiveActivityPreferencesStore {
    nonisolated static let defaultOffsets: Set<AssignmentReminderOffset> = [.hr48, .hr24, .hr8, .hr2, .hr1, .min30]
    nonisolated static let defaultAssignmentLeadTime: TimeInterval = 8 * 3600
    nonisolated static let defaultClassPreparingLeadTime: TimeInterval = 60 * 60
    nonisolated static let minimumClassPreparingLeadTime: TimeInterval = 5 * 60
    nonisolated static let maximumClassPreparingLeadTime: TimeInterval = 4 * 3600
    /// Spec invariant: Live Activity lead time must not exceed 8 hours to fit the activity lifecycle.
    nonisolated static let maximumAssignmentLeadTime: TimeInterval = 8 * 3600
    /// The class reminder lead times on offer, labelled as the assignment offsets are. They stop
    /// at an hour because the backend's push counts the lead in minutes.
    nonisolated static let classReminderLeadChoices: [AssignmentReminderOffset] = [.min5, .min10, .min15, .min30, .hr1]
    /// The backend's own default, so the first push of a device that never chose one changes
    /// no reminder.
    nonisolated static let defaultClassReminderLeadMinutes = 10

    var assignmentReminderOffsets: Set<AssignmentReminderOffset> {
        didSet {
            persistOffsets()
            guard !isApplyingRemoteUpdate else { return }
            notifyChange(isRemoteOrigin: false)
        }
    }
    /// Master switch for assignment due reminders. Synced as the
    /// `notification` document's `assignments.enabled`, which the backend
    /// checks before sending any reminder. Mirrors Android's
    /// `notifyAssignments`.
    var isAssignmentReminderEnabled: Bool {
        didSet {
            Defaults[.isAssignmentReminderEnabled] = isAssignmentReminderEnabled
            guard !isApplyingRemoteUpdate else { return }
            notifyChange(isRemoteOrigin: false)
        }
    }
    /// Class reminders, which the backend pushes before each class: the `notification`
    /// document's `courses.enabled` and its one lead time, `courses.reminder_offsets_minutes`.
    var isClassReminderEnabled: Bool {
        didSet {
            Defaults[.isClassReminderEnabled] = isClassReminderEnabled
            guard !isApplyingRemoteUpdate else { return }
            notifyChange(isRemoteOrigin: false)
        }
    }
    var classReminderLeadMinutes: Int {
        didSet {
            Defaults[.classReminderLeadMinutes] = classReminderLeadMinutes
            guard !isApplyingRemoteUpdate else { return }
            hasPickedClassReminderLead = true
            notifyChange(isRemoteOrigin: false)
        }
    }
    /// The user picked `classReminderLeadMinutes` here since the document's class reminder
    /// offsets were last adopted. Until then a push leaves those offsets as they are: they may
    /// hold values this build has no choice for, from another client or a newer build.
    private(set) var hasPickedClassReminderLead: Bool {
        didSet { Defaults[.hasPickedClassReminderLead] = hasPickedClassReminderLead }
    }
    var isLiveActivityEnabled: Bool {
        didSet {
            Defaults[.isLiveActivityEnabled] = isLiveActivityEnabled
            // Not one of the synced fields, so `applyFromNotificationSettingsDocument`
            // never assigns it and it needs no remote-origin guard. The device-only post keeps
            // the observer from writing the settings document for a change it does not carry.
            notifyChange(isRemoteOrigin: false, isDeviceOnly: true)
        }
    }
    var assignmentLiveActivityLeadTime: TimeInterval {
        didSet {
            Defaults[.assignmentLiveActivityLeadTime] = assignmentLiveActivityLeadTime
            guard !isApplyingRemoteUpdate else { return }
            notifyChange(isRemoteOrigin: false)
        }
    }
    var classPreparingLeadTime: TimeInterval {
        didSet {
            Defaults[.classPreparingLeadTime] = classPreparingLeadTime
            guard !isApplyingRemoteUpdate else { return }
            notifyChange(isRemoteOrigin: false)
        }
    }
    var showAssignmentScenario: Bool {
        didSet {
            Defaults[.showAssignmentScenario] = showAssignmentScenario
            guard !isApplyingRemoteUpdate else { return }
            notifyChange(isRemoteOrigin: false)
        }
    }
    var showClassPreparingScenario: Bool {
        didSet {
            Defaults[.showClassPreparingScenario] = showClassPreparingScenario
            guard !isApplyingRemoteUpdate else { return }
            notifyChange(isRemoteOrigin: false)
        }
    }
    var showInClassScenario: Bool {
        didSet {
            Defaults[.showInClassScenario] = showInClassScenario
            guard !isApplyingRemoteUpdate else { return }
            notifyChange(isRemoteOrigin: false)
        }
    }

    /// Set while ``applyFromNotificationSettingsDocument`` assigns properties for a
    /// backend pull. It only coalesces: it holds back the per-property `didSet` posts,
    /// one per field, and the method posts one remote-origin notification at the end.
    /// It does not silence the pull. Of the three things `liveActivityPreferencesDidChange`
    /// drives (`AppState.setupObservers`), the Live Activity refresh and push-schedule
    /// re-sync must run on new values. Only the outgoing settings push sits out, by
    /// reading ``AppConstants/liveActivityPreferencesRemoteOriginKey``, or a pull would
    /// queue a push of the data it just came from.
    private var isApplyingRemoteUpdate = false

    init() {
        if let data = Defaults[.assignmentReminderOffsetsData],
           let raws = try? JSONDecoder().decode([String].self, from: data) {
            assignmentReminderOffsets = Set(raws.compactMap { AssignmentReminderOffset(rawValue: $0) })
        } else {
            assignmentReminderOffsets = Self.defaultOffsets
        }

        isAssignmentReminderEnabled = Defaults[.isAssignmentReminderEnabled]
        isClassReminderEnabled = Defaults[.isClassReminderEnabled]
        classReminderLeadMinutes = Defaults[.classReminderLeadMinutes]
        hasPickedClassReminderLead = Defaults[.hasPickedClassReminderLead]
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
    /// Leaves the assignment and class reminder settings alone: they live on
    /// their own settings screens, and resetting them here would silently
    /// re-enable reminders the user had turned off.
    func resetToDefaults() {
        isLiveActivityEnabled = true
        assignmentLiveActivityLeadTime = Self.defaultAssignmentLeadTime
        classPreparingLeadTime = Self.defaultClassPreparingLeadTime
        showAssignmentScenario = true
        showClassPreparingScenario = true
        showInClassScenario = true
    }

    /// Applies the preferences in the `assignments`, `live_activity` and `courses` sections of
    /// the `notification` settings document (`NotificationSettingsSync.reconcile`). Each
    /// `didSet` still writes through to `Defaults`, as for a local edit.
    /// Posts `liveActivityPreferencesDidChange` once, flagged remote-origin, and only if
    /// a value changed, so one pull is one Live Activity refresh and push-schedule sync,
    /// not one per field. The flag keeps the settings push out; see ``isApplyingRemoteUpdate``.
    /// Clamps the lead times to this build's slider ranges (the `init()` maximums plus the
    /// class-preparing minimum): a value from another platform or the server may fall outside them.
    func applyFromNotificationSettingsDocument(
        isAssignmentReminderEnabled: Bool,
        assignmentReminderOffsets: Set<AssignmentReminderOffset>,
        showClassPreparingScenario: Bool,
        showInClassScenario: Bool,
        showAssignmentScenario: Bool,
        classPreparingLeadTime: TimeInterval,
        assignmentLiveActivityLeadTime: TimeInterval,
        isClassReminderEnabled: Bool,
        classReminderLeadMinutes: Int,
        hasPickedClassReminderLead: Bool
    ) {
        // The fields this method owns, read through `LocalPreferences` rather than
        // re-listed so the before/after comparison cannot drift from what is assigned below.
        let before = NotificationSettingsSync.LocalPreferences(from: self)

        isApplyingRemoteUpdate = true

        self.isAssignmentReminderEnabled = isAssignmentReminderEnabled
        self.assignmentReminderOffsets = assignmentReminderOffsets

        self.showClassPreparingScenario = showClassPreparingScenario
        self.showInClassScenario = showInClassScenario
        self.showAssignmentScenario = showAssignmentScenario

        let resolvedClassLead = classPreparingLeadTime > 0 ? classPreparingLeadTime : Self.defaultClassPreparingLeadTime
        self.classPreparingLeadTime = min(max(resolvedClassLead, Self.minimumClassPreparingLeadTime), Self.maximumClassPreparingLeadTime)

        let resolvedAssignmentLead = assignmentLiveActivityLeadTime > 0 ? assignmentLiveActivityLeadTime : Self.defaultAssignmentLeadTime
        self.assignmentLiveActivityLeadTime = min(resolvedAssignmentLead, Self.maximumAssignmentLeadTime)

        self.isClassReminderEnabled = isClassReminderEnabled
        self.classReminderLeadMinutes = classReminderLeadMinutes
        self.hasPickedClassReminderLead = hasPickedClassReminderLead

        // Cleared before the post, never by a `defer`: an observer woken by
        // it must not find the store still claiming to be mid-apply.
        isApplyingRemoteUpdate = false

        // Compared after the clamps, so a value the clamp brought back to
        // where it already was does not read as a change.
        guard NotificationSettingsSync.LocalPreferences(from: self) != before else { return }
        notifyChange(isRemoteOrigin: true)
    }

    private func persistOffsets() {
        let raws = assignmentReminderOffsets.map(\.rawValue).sorted()
        if let data = try? JSONEncoder().encode(raws) {
            Defaults[.assignmentReminderOffsetsData] = data
        } else {
            Defaults[.assignmentReminderOffsetsData] = nil
        }
    }

    /// Broadcasts that preferences changed. `AppState` debounces the follow-up so
    /// rapid changes, such as dragging a slider, do not trigger back-to-back Live
    /// Activity refreshes, push-schedule syncs and settings pushes.
    ///
    /// `isRemoteOrigin` marks values from the `notification` settings document, not
    /// the user; `isDeviceOnly`, a preference the document does not carry. Either way
    /// the observer skips only the settings push: it would bounce the pull back, or
    /// have nothing to write (`NotificationSettingsSync.changeNeedsDocumentPush`).
    private func notifyChange(isRemoteOrigin: Bool, isDeviceOnly: Bool = false) {
        var userInfo: [AnyHashable: Any] = [:]
        if isRemoteOrigin { userInfo[AppConstants.liveActivityPreferencesRemoteOriginKey] = true }
        if isDeviceOnly { userInfo[AppConstants.liveActivityPreferencesDeviceOnlyKey] = true }
        NotificationCenter.default.post(
            name: AppConstants.liveActivityPreferencesDidChange,
            object: nil,
            userInfo: userInfo.isEmpty ? nil : userInfo
        )
    }
}
