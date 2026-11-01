import Foundation
import TigerDuckCore

enum TermRoster {

    static func savedCourses(_ drawn: [SDCourse], pastTerm: Bool, live: Bool, dropped: Set<String>) -> [SDCourse]? {
        guard !drawn.isEmpty || pastTerm else { return nil }
        return pastTerm || live ? drawn : drawn.filter { !dropped.contains($0.courseNo) }
    }

    static func uploadedRoster(selection: [String]?, live: Bool, pastTerm: [String]?) -> [String]? {
        pastTerm ?? (live ? selection : nil)
    }

    static func termCourseNos(
        selection: [String]?, transcript: [String]?, cached: [String]
    ) -> (courseNos: [String], roster: [String]?)? {
        let fromSelection = uniqueCourseNos(selection ?? [])
        if !fromSelection.isEmpty { return (fromSelection, fromSelection) }
        let fromTranscript = uniqueCourseNos(transcript ?? [])
        guard !fromTranscript.isEmpty else { return nil }
        return (uniqueCourseNos(fromTranscript + cached), nil)
    }

    struct LookedUpCourse {
        let course: SDCourse
        let answered: Bool
    }

    static func rebuiltPastTerm(
        _ looked: [LookedUpCourse], unreadable: [String], cached: [SDCourse], others: [String], userAdded: [SDCourse]
    ) -> (courses: [SDCourse], roster: [String], dropping: [String]) {
        let hasTimes = { (course: SDCourse) in course.schedule.values.contains { !$0.isEmpty } }
        let cachedNos = Set(cached.map(\.courseNo))
        let courses = looked.filter { $0.answered ? hasTimes($0.course) : cachedNos.contains($0.course.courseNo) }
            .map(\.course) + cached.filter { unreadable.contains($0.courseNo) }
        let roster = looked.filter { !$0.answered || hasTimes($0.course) }.map(\.course.courseNo) + unreadable
        let addedHere = Set(userAdded.filter { $0.moodleIdNumber == nil }.map(\.courseNo))
        let merged = userAdded.filter { $0.moodleIdNumber != nil }.map(\.courseNo)
        let dropping = (Array(cachedNos) + merged + others).filter { !addedHere.contains($0) }
        return (courses, roster, dropping)
    }

    static func rebuildsFromTranscript(_ report: ScoreReport?, term: String, servedBySelection: Bool) -> Bool {
        guard !servedBySelection, let report else { return false }
        let listed = report.courses.filter { $0.status != .exempted }
        guard listed.contains(where: { $0.term == term }), let current = AcademicTerm(code: term) else { return false }
        return listed.contains { AcademicTerm(code: $0.term).map { $0 > current } ?? false }
    }

    static func drawnCourses(_ courses: [SDCourse], fromSelection: Bool, cached: Set<String>) -> [SDCourse] {
        guard !fromSelection else { return courses }
        return courses.filter { cached.contains($0.courseNo) || $0.schedule.values.contains { !$0.isEmpty } }
    }

    static func uniqueCourseNos(_ courseNos: [String]) -> [String] {
        var seen = Set<String>()
        return courseNos.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func classRows(of report: ScoreReport, term: String) -> [CourseGrade] {
        ruleRows(of: report, term: term).filter { CourseSelectionService.isCourseNo($0.code[...]) }
    }

    static func unreadableClassRows(of report: ScoreReport, term: String) -> [CourseGrade] {
        ruleRows(of: report, term: term).filter { !$0.code.isEmpty && !CourseSelectionService.isCourseNo($0.code[...]) }
    }

    private static func ruleRows(of report: ScoreReport, term: String) -> [CourseGrade] {
        report.courses.filter {
            $0.term == term && $0.status != .withdrew && $0.status != .exempted && !isEnglishProficiencyTest($0)
        }
    }

    static func isEnglishProficiencyTest(_ row: CourseGrade) -> Bool {
        row.code == "CC1011301" || row.name.trimmingCharacters(in: .whitespacesAndNewlines) == "校定英文能力檢測"
    }

    static func selectionDrops(
        previous: Set<String>,
        localPortalNos: [String],
        roster: [String],
        isFinal: Bool = false
    ) -> Set<String> {
        guard !roster.isEmpty || isFinal else { return previous }
        let enrolled = Set(roster)
        return previous.union(localPortalNos).subtracting(enrolled)
    }
}
