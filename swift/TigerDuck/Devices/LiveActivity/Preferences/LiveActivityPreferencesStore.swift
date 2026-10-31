import SwiftUI
import Defaults

func effectiveLiveActivityEnabled(isLiveActivityEnabled: Bool, cloudSyncEnabled: Bool) -> Bool {
    isLiveActivityEnabled && cloudSyncEnabled
}

@Observable
final class LiveActivityPreferencesStore {
    nonisolated static let defaultOffsets: Set<AssignmentReminderOffset> = [.hr48, .hr24, .hr8, .hr2, .hr1, .min30]
    nonisolated static let defaultAssignmentLeadTime: TimeInterval = 8 * 3600
    nonisolated static let defaultClassPreparingLeadTime: TimeInterval = 60 * 60
    nonisolated static let minimumClassPreparingLeadTime: TimeInterval = 5 * 60
    nonisolated static let maximumClassPreparingLeadTime: TimeInterval = 4 * 3600
    nonisolated static let maximumAssignmentLeadTime: TimeInterval = 8 * 3600
    nonisolated static let classReminderLeadChoices: [AssignmentReminderOffset] = [.min5, .min10, .min15, .min30, .hr1]
    nonisolated static let defaultClassReminderLeadMinutes = 10

    var assignmentReminderOffsets: Set<AssignmentReminderOffset> {
        didSet {
            persistOffsets()
            guard !isApplyingRemoteUpdate else { return }
            notifyChange(isRemoteOrigin: false)
        }
    }
    var isAssignmentReminderEnabled: Bool {
        didSet {
            Defaults[.isAssignmentReminderEnabled] = isAssignmentReminderEnabled
            guard !isApplyingRemoteUpdate else { return }
            notifyChange(isRemoteOrigin: false)
        }
    }
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
    private(set) var hasPickedClassReminderLead: Bool {
        didSet { Defaults[.hasPickedClassReminderLead] = hasPickedClassReminderLead }
    }
    var isLiveActivityEnabled: Bool {
        didSet {
            Defaults[.isLiveActivityEnabled] = isLiveActivityEnabled
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

    func resetToDefaults() {
        isLiveActivityEnabled = true
        assignmentLiveActivityLeadTime = Self.defaultAssignmentLeadTime
        classPreparingLeadTime = Self.defaultClassPreparingLeadTime
        showAssignmentScenario = true
        showClassPreparingScenario = true
        showInClassScenario = true
    }

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

        isApplyingRemoteUpdate = false

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
