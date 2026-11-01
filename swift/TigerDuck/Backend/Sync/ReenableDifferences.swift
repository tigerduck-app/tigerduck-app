import Defaults
import Foundation
import os

@MainActor
enum ReenableDifferences {
    struct Found {
        var lines: [String] = []
        let serverIgnoredCourses: [CourseIgnoresReconciler.ServerIgnoredCourse]?
        var serverMarkedAssignments = Set<String>()
    }

    static func find(
        in json: [String: Any], checking pending: Set<String>, courseDeletes: Set<String>,
        studentId: () -> String?
    ) -> Found {
        let coursesArray = json["courses"] as? [[String: Any]] ?? []
        var found = Found(serverIgnoredCourses: CourseIgnoresReconciler.serverIgnoredCourses(
            json["course_overrides"] as? [[String: Any]] ?? [], syncsCourses: Defaults[.syncCourses]
        ))

        if pending.contains("courses"),
           let line = courseLine(coursesArray, courseDeletes: courseDeletes, studentId: studentId()) {
            found.lines.append(line)
        }

        if pending.contains("course_colors") || pending.contains("course_names") {
            found.lines += overrideLines(json, coursesArray: coursesArray, pending: pending)
        }

        if pending.contains("assignments") {
            let (line, marked) = assignmentLine(json, coursesArray: coursesArray, serverIgnoredCourses: found.serverIgnoredCourses)
            found.serverMarkedAssignments = marked
            if let line { found.lines.append(line) }
        }

        AppLogger.sync.info("[reenable] result: \(found.lines.count, privacy: .public) diffs → \(found.lines.isEmpty ? "no conflict" : "SHOW POPUP", privacy: .public)")
        return found
    }

    private static func courseLine(
        _ coursesArray: [[String: Any]], courseDeletes: Set<String>, studentId: String?
    ) -> String? {
        let deletedNos = Set(CourseStore.shared.loadDeletedCourseNos())
        let userAdded = CourseStore.shared.loadUserAddedCourses()
        let serverSemesters = coursesArray.compactMap { $0["semester"] as? String }.filter { !$0.isEmpty }
        var localOnly = 0
        var serverOnly = 0
        for semester in Set(serverSemesters).union(SemesterCatalog.availableSemesters()) {
            let (serverNos, localNos) = CourseRosterReconciler.reenableCourseNos(
                coursesArray, semester: semester,
                local: Set(CourseStore.shared.loadCourses(semester: semester).map(\.courseNo))
                    .union(CourseStore.shared.loadUserAddedCourses(semester: semester).map(\.courseNo))
                    .filter { !CourseTombstone.isHidden($0, semester: semester, in: deletedNos) },
                userAdded: userAdded,
                liveAnswer: studentId.flatMap { CourseSelectionService.lastAnswer(studentId: $0, semester: semester) }
            )
            guard let counts = coursesOnOneSide(
                server: serverNos, local: localNos, semester: semester, deleting: courseDeletes
            ) else { continue }
            localOnly += counts.localOnly
            serverOnly += counts.serverOnly
            AppLogger.sync.info("[reenable] courses \(semester, privacy: .public): local=\(localNos.sorted(), privacy: .private) server=\(serverNos.sorted(), privacy: .private)")
        }
        if localOnly > 0 && serverOnly > 0 {
            return String(format: String(localized: "sync_conflict_reenable_courses"), String(localOnly), String(serverOnly))
        } else if localOnly > 0 {
            return String(format: String(localized: "sync_conflict_reenable_courses_local_only"), String(localOnly))
        } else if serverOnly > 0 {
            return String(format: String(localized: "sync_conflict_reenable_courses_server_only"), String(serverOnly))
        }
        AppLogger.sync.info("[reenable] courses MATCH — no conflict")
        return nil
    }

    private static func overrideLines(
        _ json: [String: Any], coursesArray: [[String: Any]], pending: Set<String>
    ) -> [String] {
        var lines: [String] = []
        let overrides = json["course_overrides"] as? [[String: Any]] ?? []
        var moodleIdToNo: [String: String] = [:]
        for c in coursesArray {
            guard let mId = CourseOverridesReconciler.overrideIdentity(c) else { continue }
            if let courseNo = c["course_no"] as? String, !courseNo.isEmpty {
                moodleIdToNo[mId] = courseNo
            }
        }
        AppLogger.sync.info("[reenable] overrides=\(overrides.count, privacy: .public) moodleIdMap=\(moodleIdToNo.count, privacy: .public)")

        if pending.contains("course_colors") {
            let localColorMap = TigerDuckTheme.courseColorMap
            var colorMismatches: [String] = []
            for o in overrides {
                guard let mId = CourseOverridesReconciler.overrideIdentity(o),
                      let courseNo = o["course_no"] as? String ?? moodleIdToNo[mId],
                      let serverHex = o["color_hex"] as? String, !serverHex.isEmpty else { continue }
                let localHex = localColorMap[courseNo].map { String(format: "#%06X", $0) }
                if localHex != serverHex {
                    colorMismatches.append("\(courseNo): local=\(localHex ?? "nil") server=\(serverHex)")
                }
            }
            AppLogger.sync.info("[reenable] colors: \(colorMismatches.isEmpty ? "MATCH" : "DIFFER (\(colorMismatches.count))", privacy: .public)")
            if !colorMismatches.isEmpty {
                for m in colorMismatches.prefix(5) { AppLogger.sync.debug("[reenable]   \(m, privacy: .private)") }
                lines.append(String(localized: "sync_conflict_reenable_colors_differ"))
            }
        }

        if pending.contains("course_names") {
            let nameMismatches = courseNameMismatches(
                overrides, courseNos: moodleIdToNo, local: CourseStore.shared.loadCourseCustomNames()
            )
            AppLogger.sync.info("[reenable] names: \(nameMismatches.isEmpty ? "MATCH" : "DIFFER (\(nameMismatches.count))", privacy: .public)")
            if !nameMismatches.isEmpty {
                for m in nameMismatches.prefix(5) { AppLogger.sync.debug("[reenable]   \(m, privacy: .private)") }
                lines.append(String(localized: "sync_conflict_reenable_names_differ"))
            }
        }
        return lines
    }

    private static func assignmentLine(
        _ json: [String: Any], coursesArray: [[String: Any]],
        serverIgnoredCourses: [CourseIgnoresReconciler.ServerIgnoredCourse]?
    ) -> (line: String?, serverMarked: Set<String>) {
        let overridesArray = json["assignment_overrides"] as? [[String: Any]] ?? []
        var serverArchivedIds = Set<String>()
        var serverCompletedIds = Set<String>()
        for o in overridesArray {
            guard let status = o["local_status"] as? String else { continue }
            let moodleId: String?
            if let mid = o["moodle_assignment_id"] as? Int {
                moodleId = String(mid)
            } else if let assignPk = o["user_assignment_id"] as? Int,
                      let assignments = json["assignments"] as? [[String: Any]] {
                moodleId = assignments.first(where: { ($0["id"] as? Int) == assignPk })
                    .flatMap { $0["moodle_assignment_id"] as? Int }.map(String.init)
            } else {
                moodleId = nil
            }
            guard let moodleId else { continue }
            switch status {
            case "archived", "ignored": serverArchivedIds.insert(moodleId)
            case "locally_completed": serverCompletedIds.insert(moodleId)
            default: break
            }
        }
        let serverMarkedAssignments = serverArchivedIds.union(serverCompletedIds)
        let localArchivedIds = AssignmentStore.shared.loadArchivedAssignmentIds()
        let localCompletedIds = AssignmentStore.shared.loadLocallyCompletedAssignmentIds()
        let archivedMatch = localArchivedIds == serverArchivedIds
        let completedMatch = localCompletedIds == serverCompletedIds
        let coursesDiffer = CourseIgnoresReconciler.ignoredCoursesDiffer(
            server: serverIgnoredCourses.map { Set($0.map(\.key)) },
            decided: CourseIgnoresReconciler.serverDecidedCourses(json["course_overrides"] as? [[String: Any]] ?? [])
                .union(CourseIgnoresReconciler.recreatedCourses(
                    listed: CourseIgnoresReconciler.listedCourseRows(coursesArray), seen: Defaults[.courseRowIdsSeen]
                )),
            listed: CourseIgnoresReconciler.listedCourses(coursesArray),
            local: AssignmentStore.shared.loadIgnoredAssignmentCourses(),
            snapshotSemesters: Set(coursesArray.compactMap { $0["semester"] as? String })
        )
        AppLogger.sync.info("[reenable] assignments: localArchived=\(localArchivedIds.count, privacy: .public) serverArchived=\(serverArchivedIds.count, privacy: .public) match=\(archivedMatch, privacy: .public) | localCompleted=\(localCompletedIds.count, privacy: .public) serverCompleted=\(serverCompletedIds.count, privacy: .public) match=\(completedMatch, privacy: .public) | ignoredCoursesDiffer=\(coursesDiffer, privacy: .public)")
        guard !archivedMatch || !completedMatch || coursesDiffer else { return (nil, serverMarkedAssignments) }
        return (String(localized: "sync_conflict_reenable_assignments_differ"), serverMarkedAssignments)
    }

    nonisolated static func courseNameMismatches(
        _ overrides: [[String: Any]], courseNos: [String: String], local: [String: [String: String]]
    ) -> [String] {
        var mismatches: [String] = []
        var serverNosWithNames = Set<String>()
        for o in overrides {
            guard let mId = CourseOverridesReconciler.overrideIdentity(o),
                  let courseNo = o["course_no"] as? String ?? courseNos[mId],
                  let serverNames = CourseOverridesReconciler.setOrClearedNames(in: o)?.compactMapValues({ $0 }),
                  !serverNames.isEmpty else { continue }
            serverNosWithNames.insert(courseNo)
            if (local[courseNo] ?? [:]) != serverNames {
                mismatches.append("\(courseNo): local=\(local[courseNo] ?? [:]) server=\(serverNames)")
            }
        }
        for (courseNo, locales) in local where !locales.isEmpty && !serverNosWithNames.contains(courseNo) {
            mismatches.append("\(courseNo): local=\(locales) server=default")
        }
        return mismatches
    }

    nonisolated static func coursesOnOneSide(
        server: Set<String>, local: Set<String>, semester: String, deleting: Set<String>
    ) -> (localOnly: Int, serverOnly: Int)? {
        let server = server.filter { !CourseTombstone.isHidden($0, semester: semester, in: deleting) }
        guard !server.isEmpty, !local.isEmpty else { return nil }
        return (local.subtracting(server).count, server.subtracting(local).count)
    }
}
