import Foundation
import TigerDuckCore

/// Which courses a term holds, read from course selection's answer, the transcript and the cache.
enum TermRoster {

    /// The courses a fetch saves, or nil when it drew none and the term keeps its cache. Those
    /// dropped on the server are read as it saves: a full sync during its lookups may drop one a
    /// cached course selection answer or the transcript still lists, and a fetch whose every
    /// course was dropped saves none. Only a live answer or a past term's final transcript brings
    /// one back.
    static func savedCourses(_ drawn: [SDCourse], pastTerm: Bool, live: Bool, dropped: Set<String>) -> [SDCourse]? {
        guard !drawn.isEmpty || pastTerm else { return nil }
        return pastTerm || live ? drawn : drawn.filter { !dropped.contains($0.courseNo) }
    }

    /// The roster a fetch uploads: a past term's final transcript, or course selection's answer
    /// only when this fetch got it from the school. One cached for up to a day may still name a
    /// course another device's roster dropped since, and would enroll it again.
    static func uploadedRoster(selection: [String]?, live: Bool, pastTerm: [String]?) -> [String]? {
        pastTerm ?? (live ? selection : nil)
    }

    /// A term's course numbers, or nil when no source answers and the term keeps its cached
    /// courses. Course selection's answer owns the term it serves and is the roster its drops are
    /// read from. Any other term, or that one when course selection gives nothing, adds the
    /// transcript's classes to its cached courses: a transcript lists a running term late or in
    /// part, so it never removes one. Moodle lists course sites and keeps a dropped class, so it
    /// adds none. An empty list counts as nil: the D01 regex scrape returns no matches, not an
    /// error, when the page drifts.
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
        /// Whether the course query found the course; when it did not, `course` is the cached copy
        /// or one built from Moodle and the transcript.
        let answered: Bool
    }

    /// A past term rebuilt from the transcript: its classes the course query found with class
    /// times, and the cached copy of one it did not find or of an `unreadable` row it cannot look
    /// up, as neither removes a course. `roster` names those and the classes still waiting for a
    /// lookup. Every other course the term may hold here or on the server, cached, merged from the
    /// server, a Moodle site or a row the rule leaves out in `others`, is in `dropping`, so its
    /// server row is not merged back. A course added by hand is never dropped.
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

    /// A term the transcript lists is rebuilt only once it lists a later one too: then the term
    /// has ended and the transcript holds all of it, even when that leaves no class to draw. The
    /// newest term listed may still run or miss grades, and the term course selection serves is
    /// its own, so both only add. An exempted row can be filed under any term and counts for neither.
    static func rebuildsFromTranscript(_ report: ScoreReport?, term: String, servedBySelection: Bool) -> Bool {
        guard !servedBySelection, let report else { return false }
        let listed = report.courses.filter { $0.status != .exempted }
        guard listed.contains(where: { $0.term == term }), let current = AcademicTerm(code: term) else { return false }
        return listed.contains { AcademicTerm(code: $0.term).map { $0 > current } ?? false }
    }

    /// A class the transcript adds joins its term only with class times: a row without them, or one
    /// whose lookup failed, has nothing to draw, and a later fetch adds it once the lookup answers.
    /// Course selection's courses and the term's cached ones stay as they are.
    static func drawnCourses(_ courses: [SDCourse], fromSelection: Bool, cached: Set<String>) -> [SDCourse] {
        guard !fromSelection else { return courses }
        return courses.filter { cached.contains($0.courseNo) || $0.schedule.values.contains { !$0.isEmpty } }
    }

    static func uniqueCourseNos(_ courseNos: [String]) -> [String] {
        var seen = Set<String>()
        return courseNos.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The term's transcript rows that stand for a class. Withdrawn and exempted rows and the
    /// school English proficiency test have none to draw. Codes are read with
    /// `CourseSelectionService.isCourseNo`, which takes NTU and NTNU courses too.
    static func classRows(of report: ScoreReport, term: String) -> [CourseGrade] {
        ruleRows(of: report, term: term).filter { CourseSelectionService.isCourseNo($0.code[...]) }
    }

    /// The rows the rule keeps whose code is no course number, so the course query cannot look
    /// them up.
    static func unreadableClassRows(of report: ScoreReport, term: String) -> [CourseGrade] {
        ruleRows(of: report, term: term).filter { !$0.code.isEmpty && !CourseSelectionService.isCourseNo($0.code[...]) }
    }

    private static func ruleRows(of report: ScoreReport, term: String) -> [CourseGrade] {
        report.courses.filter {
            $0.term == term && $0.status != .withdrew && $0.status != .exempted && !isEnglishProficiencyTest($0)
        }
    }

    /// The school English proficiency test, a graduation requirement the transcript files as a
    /// course row, under its own course number or, should that change, its exact name.
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
