import Foundation
import TigerDuckCore

@MainActor
final class MoodleMemberCourses {
    private let courseId: Int
    private let members: MoodleFeed<MoodleMemberList>
    private let api: MoodleCourseAPI
    private let context: MoodleCacheContext
    private let classTable: CourseStore
    private var feeds: [Int: MoodleFeed<[MoodleEnrolledCourse]>] = [:]
    private var grouped: [Int: Grouped] = [:]

    private struct Grouped {
        let fetchedAt: Date?
        let classTableRevision: Int
        let terms: [MoodleCommonTerm]
    }

    init(
        courseId: Int, members: MoodleFeed<MoodleMemberList>, api: MoodleCourseAPI, context: MoodleCacheContext,
        classTable: CourseStore
    ) {
        self.courseId = courseId
        self.members = members
        self.api = api
        self.context = context
        self.classTable = classTable
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
        let own = Set(context.cache.loadMoodleCourseIdMap().values)
        guard isSomeoneElse(member), !own.isEmpty,
              (try? await api.functions())?.contains(MoodleEnrolledCoursesService.usersCoursesFunction) == true
        else { return }
        await feed(of: member).refresh { [api] in
            // Moodle also lists another user's courses the account can merely see, such as open ones.
            try await api.sharedCourses(member.id).filter { own.contains($0.id) }
        }
    }

    func terms(with member: MoodleMember) -> [MoodleCommonTerm] {
        guard isSomeoneElse(member) else { return [] }
        let feed = feed(of: member)
        let revision = classTable.revision
        if let kept = grouped[member.id], kept.fetchedAt == feed.fetchedAt, kept.classTableRevision == revision {
            return kept.terms
        }
        let terms = feed.value.map { shared in
            MoodleCommonTerm.terms(of: shared, besides: courseId) { classTable.loadCourses(semester: $0) }
        } ?? []
        grouped[member.id] = Grouped(fetchedAt: feed.fetchedAt, classTableRevision: revision, terms: terms)
        return terms
    }

    private func isSomeoneElse(_ member: MoodleMember) -> Bool {
        guard let ownId = members.value?.ownId else { return false }
        return member.id != ownId
    }
}

nonisolated struct MoodleCommonTerm: Identifiable, Equatable {
    let term: String?
    let courses: [MoodleCommonCourse]

    var id: String { term ?? "" }
}

nonisolated struct MoodleCommonCourse: Identifiable, Equatable {
    let id: Int
    let name: String
    let details: [String]
    let colorKey: String
}

@MainActor
extension MoodleCommonTerm {
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
