import Defaults
import Foundation

nonisolated struct SyncPolicy: Equatable, Sendable {
    let cloudSyncEnabled: Bool
    let switchedOn: Set<SyncCategory>
    let pendingChecks: Set<SyncCategory>

    static var current: SyncPolicy {
        var switchedOn: Set<SyncCategory> = []
        if Defaults[.syncCourses] { switchedOn.insert(.courses) }
        if Defaults[.syncCourseColors] { switchedOn.insert(.courseColors) }
        if Defaults[.syncCourseNames] { switchedOn.insert(.courseNames) }
        if Defaults[.syncAssignments] { switchedOn.insert(.assignments) }
        return SyncPolicy(
            cloudSyncEnabled: Defaults[.cloudSyncEnabled],
            switchedOn: switchedOn,
            pendingChecks: Defaults[.pendingConflictCategories]
        )
    }

    var uploadsCourses: Bool {
        cloudSyncEnabled && (Self.backendRemindersNeedTheRoster || switchedOn.contains(.courses))
    }

    #if os(macOS)
    private static let backendRemindersNeedTheRoster = false
    #else
    private static let backendRemindersNeedTheRoster = true
    #endif

    var sendsAssignmentMarks: Bool {
        switchedOn.contains(.assignments) && !pendingChecks.contains(.assignments)
    }

    var sendsCourseIgnores: Bool {
        sendsAssignmentMarks && switchedOn.contains(.courses)
    }

    func sendsCourseOverride(_ category: SyncCategory) -> Bool {
        !pendingChecks.contains(category)
    }

    func categoriesTaken(marksLeftFor reason: MarksLeftReason?) -> Set<SyncCategory> {
        let holdsCourseOverrides = pendingChecks.contains(.courseColors) || pendingChecks.contains(.courseNames)
        return switchedOn.filter { category in
            switch category {
            case .assignments: reason == nil || reason == .uploadedLocalMarks
            case .courseColors, .courseNames: !holdsCourseOverrides
            case .courses: !pendingChecks.contains(category)
            }
        }
    }

    nonisolated enum MarksLeftReason: String, Sendable {
        case switchedOff = "Assignments sync is off"
        case conflictCheckPending = "conflict check pending"
        case uploadedLocalMarks = "local marks just uploaded"
        case editedDuringFetch = "local edit during fetch"
    }

    static func reasonToLeaveMarks(
        syncsMarks: Bool,
        conflictCheckPending: Bool,
        uploadedLocalMarks: Bool,
        editedDuringFetch: Bool
    ) -> MarksLeftReason? {
        if !syncsMarks { return .switchedOff }
        if conflictCheckPending { return .conflictCheckPending }
        if uploadedLocalMarks { return .uploadedLocalMarks }
        if editedDuringFetch { return .editedDuringFetch }
        return nil
    }
}
