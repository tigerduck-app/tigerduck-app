import Foundation

enum AssignmentRecords {

    static func moodleCourseIdMap(_ courses: [MoodleEnrolledCourse]) -> [String: Int] {
        var map: [String: Int] = [:]
        for course in courses {
            for alias in course.idnumbers.dropFirst() {
                let key = SDCourse.normalizedMoodleId(alias)
                if map[key] == nil { map[key] = course.id }
            }
        }
        for course in courses where !course.idnumber.isEmpty {
            map[SDCourse.normalizedMoodleId(course.idnumber)] = course.id
        }
        return map
    }

    static func assignmentCourseNo(
        for course: MoodleEnrolledCourse,
        localCourseNos: Set<String>
    ) -> String {
        course.courseNos.first(where: localCourseNos.contains) ?? course.courseNo
    }

    static func moodleCalendarEvent(_ assignment: SDAssignment) -> SDCalendarEvent {
        SDCalendarEvent(
            eventId: assignment.calendarEventId,
            title: assignment.displayTitle,
            date: assignment.dueDate,
            source: .moodle
        )
    }

    static func assignments(
        from records: [MoodleAssignmentRecord],
        moodleCoursesById: [Int: MoodleEnrolledCourse],
        courseNoByMoodleId: [Int: String],
        statuses: [Int: MoodleSubmissionStatus],
        confirmed: [String: Date],
        extensions: [String: Date] = [:],
        marks: AssignmentMarks
    ) -> [SDAssignment] {
        records.compactMap { record in
            let status = statuses[record.assignId]
            let assignmentId = String(record.assignId)
            let extensionDate = status == nil ? extensions[assignmentId] : status?.extensionDueDate
            guard let dueDate = record.dueDate else { return nil }
            guard !record.noSubmissions else { return nil }

            let moodleCourse = moodleCoursesById[record.courseId]
            let confirmedAt = confirmed[assignmentId]
            return marks.apply(to: SDAssignment(
                assignmentId: assignmentId,
                courseNo: moodleCourse.flatMap { courseNoByMoodleId[$0.id] } ?? "",
                courseName: moodleCourse.map { courseName(from: $0.fullname) } ?? "",
                title: record.name,
                dueDate: dueDate,
                isCompleted: status?.isSubmitted ?? (confirmedAt != nil),
                moodleUrl: "\(AppConstants.moodleBaseURL.absoluteString)/mod/assign/view.php?id=\(record.cmId)",
                cutoffDate: record.cutoffDate,
                submittedAt: status?.submittedAt ?? confirmedAt,
                extensionDueDate: extensionDate,
                semester: marks.semester
            ))
        }
    }

    static func recordsToAskAbout(
        _ records: [MoodleAssignmentRecord],
        confirmed: [String: Date],
        closed: ClosedUnsubmittedAnswerTimes
    ) -> [MoodleAssignmentRecord] {
        records.filter { record in
            let id = String(record.assignId)
            return record.dueDate != nil && !record.noSubmissions && confirmed[id] == nil
                && !isClosed(record, askedAt: closed[id])
        }
    }

    static func closedUnsubmitted(
        records: [MoodleAssignmentRecord],
        statuses: [Int: MoodleSubmissionStatus],
        askedAt: Date,
        kept: ClosedUnsubmittedAnswerTimes
    ) -> ClosedUnsubmittedAnswerTimes {
        var closed: ClosedUnsubmittedAnswerTimes = [:]
        for record in records {
            let id = String(record.assignId)
            if let status = statuses[record.assignId] {
                // An extension takes this student's submission past the cutoff.
                if !status.isSubmitted, isClosed(record, askedAt: askedAt),
                   (status.extensionDueDate ?? .distantPast) < askedAt { closed[id] = askedAt }
            } else if let keptAt = kept[id], isClosed(record, askedAt: keptAt) {
                closed[id] = keptAt
            }
        }
        return closed
    }

    private static func isClosed(_ record: MoodleAssignmentRecord, askedAt: Date?) -> Bool {
        guard let askedAt, let cutoff = record.cutoffDate else { return false }
        return cutoff < askedAt
    }

    /// Moodle keeps past enrolments, so a retaken course has one for each term it was taken in.
    static func coursesForTerm(_ courses: [MoodleEnrolledCourse], semester: String) -> [MoodleEnrolledCourse] {
        let byCourseNo = Dictionary(grouping: courses, by: \.courseNo)
        return courses.filter { course in
            guard let siblings = byCourseNo[course.courseNo], siblings.count > 1 else { return true }
            if siblings.contains(where: { $0.semester == semester }) { return course.semester == semester }
            let latest = siblings.max { ($0.startDate ?? .distantPast, $0.id) < ($1.startDate ?? .distantPast, $1.id) }
            return course.id == latest?.id
        }
    }

    /// Moodle keeps a submission once it has a time, short of a teacher reverting it to a draft.
    static func confirmedSubmissions(in cached: [SDAssignment]) -> [String: Date] {
        Dictionary(
            cached.compactMap { assignment in
                guard assignment.isCompleted, let submittedAt = assignment.submittedAt else { return nil }
                return (assignment.assignmentId, submittedAt)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    static func preserveCompletionState(
        freshAssignments: [SDAssignment],
        cachedAssignments: [SDAssignment],
        answeredIds: Set<String>
    ) -> [SDAssignment] {
        let previousById = Dictionary(
            uniqueKeysWithValues: cachedAssignments.map { ($0.assignmentId, $0) }
        )

        for assignment in freshAssignments where !answeredIds.contains(assignment.assignmentId) {
            guard let previous = previousById[assignment.assignmentId],
                  previous.isCompleted else { continue }
            assignment.isCompleted = true
            if assignment.submittedAt == nil {
                assignment.submittedAt = previous.submittedAt
            }
        }

        return freshAssignments
    }

    static func courseName(from fullname: String) -> String {
        let parts = fullname.components(separatedBy: " ")
        guard parts.count >= 2 else { return fullname }

        if let index = parts.firstIndex(where: { CourseSelectionService.isCourseNo($0[...]) }), index + 1 < parts.count {
            return parts[(index + 1)...].joined(separator: " ")
        }

        return fullname
    }
}
