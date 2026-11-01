import Foundation
import Defaults

nonisolated struct NotificationSettingsLocalPreferences: Equatable, Sendable, Codable {
    var isAssignmentReminderEnabled: Bool
    var assignmentReminderOffsets: Set<AssignmentReminderOffset>
    var showClassPreparingScenario: Bool
    var showInClassScenario: Bool
    var showAssignmentScenario: Bool
    var classPreparingLeadTime: TimeInterval
    var assignmentLiveActivityLeadTime: TimeInterval
    var isClassReminderEnabled: Bool
    var classReminderLeadMinutes: Int
    var hasPickedClassReminderLead: Bool

    init(
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
        self.isAssignmentReminderEnabled = isAssignmentReminderEnabled
        self.assignmentReminderOffsets = assignmentReminderOffsets
        self.showClassPreparingScenario = showClassPreparingScenario
        self.showInClassScenario = showInClassScenario
        self.showAssignmentScenario = showAssignmentScenario
        self.classPreparingLeadTime = classPreparingLeadTime
        self.assignmentLiveActivityLeadTime = assignmentLiveActivityLeadTime
        self.isClassReminderEnabled = isClassReminderEnabled
        self.classReminderLeadMinutes = classReminderLeadMinutes
        self.hasPickedClassReminderLead = hasPickedClassReminderLead
    }

    @MainActor
    init(from store: LiveActivityPreferencesStore) {
        self.init(
            isAssignmentReminderEnabled: store.isAssignmentReminderEnabled,
            assignmentReminderOffsets: store.assignmentReminderOffsets,
            showClassPreparingScenario: store.showClassPreparingScenario,
            showInClassScenario: store.showInClassScenario,
            showAssignmentScenario: store.showAssignmentScenario,
            classPreparingLeadTime: store.classPreparingLeadTime,
            assignmentLiveActivityLeadTime: store.assignmentLiveActivityLeadTime,
            isClassReminderEnabled: store.isClassReminderEnabled,
            classReminderLeadMinutes: store.classReminderLeadMinutes,
            hasPickedClassReminderLead: store.hasPickedClassReminderLead
        )
    }

    func replacing(_ section: NotificationSettingsSync.OwnedSection, from other: NotificationSettingsLocalPreferences) -> NotificationSettingsLocalPreferences {
        var copy = self
        switch section {
        case .assignments:
            copy.isAssignmentReminderEnabled = other.isAssignmentReminderEnabled
            copy.assignmentReminderOffsets = other.assignmentReminderOffsets
        case .liveActivity:
            copy.showClassPreparingScenario = other.showClassPreparingScenario
            copy.showInClassScenario = other.showInClassScenario
            copy.showAssignmentScenario = other.showAssignmentScenario
            copy.classPreparingLeadTime = other.classPreparingLeadTime
            copy.assignmentLiveActivityLeadTime = other.assignmentLiveActivityLeadTime
        case .courses:
            copy.isClassReminderEnabled = other.isClassReminderEnabled
            copy.classReminderLeadMinutes = other.classReminderLeadMinutes
            copy.hasPickedClassReminderLead = other.hasPickedClassReminderLead
        }
        return copy
    }

    func taking(_ fields: [String: Any], from other: NotificationSettingsLocalPreferences) -> NotificationSettingsLocalPreferences {
        let sent = { (section: NotificationSettingsSync.OwnedSection) in
            Set((fields[section.rawValue] as? [String: Any] ?? [:]).keys)
        }
        let assignments = sent(.assignments), liveActivity = sent(.liveActivity), courses = sent(.courses)
        var copy = self
        if assignments.contains("enabled") {
            copy.isAssignmentReminderEnabled = other.isAssignmentReminderEnabled
        }
        if !assignments.isDisjoint(with: ["reminder_offsets_minutes", "reminder_offsets_hours"]) {
            copy.assignmentReminderOffsets = other.assignmentReminderOffsets
        }
        if liveActivity.contains("show_class_preparing") {
            copy.showClassPreparingScenario = other.showClassPreparingScenario
        }
        if liveActivity.contains("show_in_class") { copy.showInClassScenario = other.showInClassScenario }
        if liveActivity.contains("show_assignment") { copy.showAssignmentScenario = other.showAssignmentScenario }
        if liveActivity.contains("class_preparing_lead_seconds") {
            copy.classPreparingLeadTime = other.classPreparingLeadTime
        }
        if liveActivity.contains("assignment_lead_seconds") {
            copy.assignmentLiveActivityLeadTime = other.assignmentLiveActivityLeadTime
        }
        if courses.contains("enabled") { copy.isClassReminderEnabled = other.isClassReminderEnabled }
        if courses.contains("reminder_offsets_minutes") {
            copy.classReminderLeadMinutes = other.classReminderLeadMinutes
            copy.hasPickedClassReminderLead = other.hasPickedClassReminderLead
        }
        return copy
    }

    var reminderOffsetsMinutes: [Int] {
        assignmentReminderOffsets
            .map { Int(($0.timeInterval / 60).rounded()) }
            .sorted(by: >)
    }

    func assignmentsSection(
        preservingForeignMinutesFrom existing: [String: Any]
    ) -> NotificationSettingsDocument.Assignments {
        let foreign = NotificationSettingsSync.foreignMinutes(in: existing)
        let minutes = Set(reminderOffsetsMinutes + foreign).sorted(by: >)
        return .init(
            enabled: isAssignmentReminderEnabled,
            reminderOffsetsHours: minutes.filter { $0 >= 60 && $0 % 60 == 0 }.map { $0 / 60 },
            reminderOffsetsMinutes: minutes
        )
    }

    var liveActivitySection: NotificationSettingsDocument.LiveActivity {
        .init(
            showClassPreparing: showClassPreparingScenario,
            showInClass: showInClassScenario,
            showAssignment: showAssignmentScenario,
            classPreparingLeadSeconds: Int(classPreparingLeadTime),
            assignmentLeadSeconds: Int(assignmentLiveActivityLeadTime)
        )
    }

    func coursesSection(
        preservingOffsetsIn existing: [String: Any]
    ) -> NotificationSettingsDocument.Courses {
        let writesLead = hasPickedClassReminderLead
            || NotificationSettingsSync.classReminderOffsets(in: existing) == nil
        return .init(
            enabled: isClassReminderEnabled,
            reminderOffsetsMinutes: writesLead ? [classReminderLeadMinutes] : nil
        )
    }

    func documentUpdates(
        existing: [String: Any],
        since synced: NotificationSettingsLocalPreferences? = nil,
        includeAssignments: Bool = true,
        includeLiveActivity: Bool = true,
        includeCourses: Bool = true
    ) throws -> [String: Any] {
        var updates: [String: Any] = [:]
        if includeAssignments {
            updates["assignments"] = try NotificationSettingsSync.jsonObject(
                assignmentsSection(preservingForeignMinutesFrom: existing)
            )
        }
        if includeLiveActivity {
            updates["live_activity"] = try NotificationSettingsSync.jsonObject(liveActivitySection)
        }
        if includeCourses {
            updates["courses"] = try NotificationSettingsSync.jsonObject(
                coursesSection(preservingOffsetsIn: existing)
            )
        }
        guard let synced else { return updates }
        let before = try synced.documentUpdates(
            existing: existing,
            includeAssignments: includeAssignments,
            includeLiveActivity: includeLiveActivity,
            includeCourses: includeCourses
        )
        return NotificationSettingsSync.changes(in: updates, since: before, over: existing)
    }
}
