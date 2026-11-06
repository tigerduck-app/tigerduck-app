import Foundation
import TigerDuckCore

/// The courses the account shares with each member of a course, which Moodle answers one member
/// at a time.
@MainActor
final class MoodleMemberCourses {
    private let courseId: Int
    private let members: MoodleFeed<MoodleMemberList>
    private let api: MoodleCourseAPI
    private let context: MoodleCacheContext
    private var feeds: [Int: MoodleFeed<[MoodleEnrolledCourse]>] = [:]

    init(courseId: Int, members: MoodleFeed<MoodleMemberList>, api: MoodleCourseAPI, context: MoodleCacheContext) {
        self.courseId = courseId
        self.members = members
        self.api = api
        self.context = context
    }

    func feed(of member: MoodleMember) -> MoodleFeed<[MoodleEnrolledCourse]> {
        if let feed = feeds[member.id] { return feed }
        let feed = MoodleFeed<[MoodleEnrolledCourse]>(
            cacheName: "members/\(member.id)/courses", ttl: MoodleRefreshInterval.members, context: context
        )
        feeds[member.id] = feed
        return feed
    }

    func refresh(with member: MoodleMember) async {
        guard !isOwn(member) else { return }
        await feed(of: member).refresh { [api] in
            try await api.ifAllowed(MoodleEnrolledCoursesService.usersCoursesFunction, else: []) {
                try await api.sharedCourses(member.id)
            }
        }
    }

    /// Nil `classTable` reads the account's class table.
    func terms(with member: MoodleMember, classTable: ((_ term: String) -> [CourseStore.Course])? = nil) -> [MoodleCommonTerm] {
        guard !isOwn(member), let shared = feed(of: member).value else { return [] }
        return MoodleCommonTerm.terms(
            of: shared, besides: courseId, classTable: classTable ?? { CourseStore.shared.loadCourses(semester: $0) }
        )
    }

    private func isOwn(_ member: MoodleMember) -> Bool { member.id == members.value?.ownId }
}

nonisolated struct MoodleCommonTerm: Identifiable, Equatable {
    /// Nil for the courses whose Moodle id names no term.
    let term: String?
    let courses: [MoodleCommonCourse]

    var id: String { term ?? "" }
}

nonisolated struct MoodleCommonCourse: Identifiable, Equatable {
    let id: Int
    let name: String
    let details: [String]
    /// The course number its colour is kept under, or the Moodle id for a course of no term.
    let colorKey: String
}

@MainActor
extension MoodleCommonTerm {
    /// The newest term first and the courses of no term last, each term's courses by name.
    static func terms(
        of shared: [MoodleEnrolledCourse], besides courseId: Int, classTable: (_ term: String) -> [CourseStore.Course]
    ) -> [MoodleCommonTerm] {
        Dictionary(grouping: shared.filter { $0.id != courseId }) { AcademicTerm(code: $0.semester) }
            .sorted { lhs, rhs in
                guard let left = lhs.key else { return false }
                return rhs.key.map { left > $0 } ?? true
            }
            .map { term, courses in
                let table = term.map { classTable($0.code) }
                return MoodleCommonTerm(
                    term: term?.code,
                    courses: courses.map { MoodleCommonCourse.listing($0, inTermOf: table) }.sorted(by: MoodleCommonCourse.byName)
                )
            }
    }
}

@MainActor
extension MoodleCommonCourse {
    /// Under the name the class table gives it in its term, else Moodle's; `table` is nil for a
    /// course of no term.
    static func listing(_ course: MoodleEnrolledCourse, inTermOf table: [CourseStore.Course]?) -> MoodleCommonCourse {
        let moodleName = AssignmentRecords.courseName(from: course.fullname)
        guard let table else {
            return MoodleCommonCourse(id: course.id, name: moodleName, details: [], colorKey: String(course.id))
        }
        let courseNo = AssignmentRecords.assignmentCourseNo(for: course, localCourseNos: Set(table.map(\.courseNo)))
        guard let known = table.first(where: { $0.courseNo == courseNo }) else {
            return MoodleCommonCourse(id: course.id, name: moodleName, details: [courseNo], colorKey: courseNo)
        }
        return MoodleCommonCourse(
            id: course.id, name: known.displayName,
            details: [known.courseNo, known.instructor].filter { !$0.isEmpty }, colorKey: known.courseNo
        )
    }

    nonisolated static func byName(_ lhs: MoodleCommonCourse, _ rhs: MoodleCommonCourse) -> Bool {
        let order = lhs.name.localizedStandardCompare(rhs.name)
        return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }
}
