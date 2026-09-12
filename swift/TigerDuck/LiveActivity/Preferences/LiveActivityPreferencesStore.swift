import SwiftUI
import Defaults

/// Centralizes Live Activity / reminder related preferences so `AppState`
/// does not keep accumulating unrelated toggles.
///
/// Defaults:
/// - `assignmentReminderOffsets`: 6 high-signal offsets (48h/24h/8h/2h/1h/30m).
///   Users can opt into denser coverage in Settings.
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
    var isLiveActivityEnabled: Bool {
        didSet {
            Defaults[.isLiveActivityEnabled] = isLiveActivityEnabled
            // Not one of the seven synced fields, so
            // `applyFromNotificationSettingsDocument` never assigns it and
            // it needs no remote-origin suppression. The post says so, so
            // the observer does not write the settings document over a
            // change the document does not carry.
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

    /// Set while ``applyFromNotificationSettingsDocument`` is assigning
    /// properties on behalf of a pull from the backend.
    ///
    /// This coalesces only: it holds back the per-property `didSet` posts —
    /// up to seven for one pull — and the method posts a single
    /// remote-origin notification at the end instead. It does **not**
    /// silence the pull. `liveActivityPreferencesDidChange` drives three
    /// separate things (`AppState.setupObservers`), and two of them —
    /// refreshing this device's Live Activity and re-syncing its push
    /// schedule — are exactly what has to happen when new preference values
    /// arrive. Only the third, the outgoing settings push, must sit out, or
    /// applying a pull would immediately queue a push of the data it just
    /// came from; that one is skipped by reading
    /// ``AppConstants/liveActivityPreferencesRemoteOriginKey`` off the
    /// notification.
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
    /// (`NotificationSettingsSync.reconcile`). Persists exactly like a
    /// local edit — each property's normal `didSet` still runs and writes
    /// through to `Defaults`.
    ///
    /// Posts `liveActivityPreferencesDidChange` **once**, flagged as
    /// remote-origin, and only if a value actually moved. Once, rather than
    /// once per assigned property, because seven posts would be seven Live
    /// Activity refreshes and seven push-schedule syncs for one pull. Only
    /// on a real change, because a pull that confirms what this device
    /// already had is not news. Flagged, so the outgoing settings push sits
    /// this one out while the other two observers still run — see
    /// ``isApplyingRemoteUpdate``.
    ///
    /// Clamps the two lead times to this build's slider ranges — the same
    /// maximums `init()` applies, plus the class-preparing minimum, which
    /// `init()` does not: a value from another platform (or a future
    /// server-side default) is not bound by those ranges.
    func applyFromNotificationSettingsDocument(
        isAssignmentReminderEnabled: Bool,
        assignmentReminderOffsets: Set<AssignmentReminderOffset>,
        showClassPreparingScenario: Bool,
        showInClassScenario: Bool,
        showAssignmentScenario: Bool,
        classPreparingLeadTime: TimeInterval,
        assignmentLiveActivityLeadTime: TimeInterval
    ) {
        // The seven fields this method owns, exactly — reused rather than
        // re-listed so the before/after comparison can never drift out of
        // step with what is assigned below.
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

    /// Broadcasts that one or more preferences changed. AppState debounces
    /// what follows so rapid changes (e.g. dragging a slider) do not trigger
    /// many back-to-back Live Activity refreshes, push-schedule syncs and
    /// settings pushes.
    ///
    /// `isRemoteOrigin` marks a post whose values came from the
    /// `notification` settings document rather than from the user, and
    /// `isDeviceOnly` one for a preference the document does not carry. The
    /// observer runs every side effect either way except the outgoing
    /// settings push: for the first it would bounce the pull straight back
    /// as a push of the same data, for the second it would have nothing to
    /// write (`NotificationSettingsSync.changeNeedsDocumentPush`).
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
