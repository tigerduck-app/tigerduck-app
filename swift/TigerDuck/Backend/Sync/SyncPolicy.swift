import Defaults
import Foundation

nonisolated struct SyncPolicy: Equatable, Sendable {
    let cloudSyncEnabled: Bool
    let switchedOn: Set<String>
    let pendingChecks: Set<String>

    static var current: SyncPolicy {
        var switchedOn: Set<String> = []
        if Defaults[.syncCourses] { switchedOn.insert("courses") }
        if Defaults[.syncCourseColors] { switchedOn.insert("course_colors") }
        if Defaults[.syncCourseNames] { switchedOn.insert("course_names") }
        if Defaults[.syncAssignments] { switchedOn.insert("assignments") }
        return SyncPolicy(
            cloudSyncEnabled: Defaults[.cloudSyncEnabled],
            switchedOn: switchedOn,
            pendingChecks: Defaults[.pendingConflictCategories]
        )
    }

    var uploadsCourses: Bool {
        guard cloudSyncEnabled else { return false }
        #if os(macOS)
        return switchedOn.contains("courses")
        #else
        return true
        #endif
    }

    var sendsAssignmentMarks: Bool {
        switchedOn.contains("assignments") && !pendingChecks.contains("assignments")
    }

    var sendsCourseIgnores: Bool {
        sendsAssignmentMarks && switchedOn.contains("courses")
    }

    func sendsCourseOverride(_ category: String) -> Bool {
        !pendingChecks.contains(category)
    }

    func categoriesTaken(marksLeftFor reason: MarksLeftReason?) -> Set<String> {
        let holdsCourseOverrides = pendingChecks.contains("course_colors") || pendingChecks.contains("course_names")
        return switchedOn.filter { category in
            switch category {
            case "assignments": reason == nil || reason == .uploadedLocalMarks
            case "course_colors", "course_names": !holdsCourseOverrides
            default: !pendingChecks.contains(category)
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
