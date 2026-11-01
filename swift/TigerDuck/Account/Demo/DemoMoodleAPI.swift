import Foundation
import os

nonisolated extension MoodleCourseAPI {
    static func serving(_ signIn: SignIn) -> MoodleCourseAPI {
        guard signIn.isDemo, let demo = bundledDemo else { return .live }
        return demo
    }

    private static let bundledDemo: MoodleCourseAPI? = DemoMoodleCourses.bundled.map(demo)

    static func demo(_ moodle: DemoMoodleCourses) -> MoodleCourseAPI {
        let read = OSAllocatedUnfairLock(initialState: Set<Int>())
        let unread: @Sendable (MoodleDiscussion) -> Int = { discussion in
            read.withLock { $0.contains(discussion.id) } ? 0 : discussion.unreadCount
        }
        return MoodleCourseAPI(
            functions: { DemoMoodleCourses.functions },
            forums: { courseIds in moodle.forums(in: courseIds, unread: unread) },
            discussions: { forumId, page in
                let list = moodle.course { $0.newsForumId == forumId }?.announcements
                    ?? moodle.courses.flatMap(\.forums).first { $0.id == forumId }?.discussions ?? []
                return list.sorted { $0.modified > $1.modified }
                    .dropFirst(page * MoodleForumService.discussionsPerPage)
                    .prefix(MoodleForumService.discussionsPerPage)
                    .map { discussion in
                        var shown = discussion
                        shown.unreadCount = unread(discussion)
                        return shown
                    }
            },
            posts: { discussionId in
                let posts = moodle.courses.flatMap(\.forums).lazy.compactMap { $0.posts[discussionId] }.first ?? []
                guard read.withLock({ $0.contains(discussionId) }) else { return posts }
                return posts.map { post in
                    var seen = post
                    seen.isUnread = false
                    return seen
                }
            },
            markViewed: { discussionId, signIn in
                guard signIn.isCurrent else { return }
                _ = read.withLock { $0.insert(discussionId) }
            },
            materials: { moodle.course($0)?.materials ?? MoodleCourseMaterials(sections: []) },
            download: { _, _ in throw URLError(.notConnectedToInternet) },
            members: { MoodleMemberList(ownId: moodle.ownMemberId, members: moodle.course($0)?.members ?? []) },
            picture: { _ in throw URLError(.notConnectedToInternet) },
            gradeItems: { moodle.course($0)?.grades ?? [] },
            summary: { moodle.course($0)?.summary ?? .empty },
            submission: { assignId in
                guard var submission = moodle.assignment(assignId)?.submission else {
                    return MoodleAssignmentSubmission(
                        status: nil, modified: nil, files: [], onlineText: nil, id: nil, takesComments: false, groupId: nil
                    )
                }
                submission.comments = nil
                submission.groupName = nil
                return submission
            },
            comments: { cmid, submissionId in
                moodle.courses.flatMap(\.assignments)
                    .first { $0.cmid == cmid && $0.submission?.id == submissionId }?.submission?.comments ?? []
            },
            groups: { courseId in
                let named = (moodle.course(courseId)?.assignments ?? []).compactMap { assignment -> (Int, String)? in
                    guard let submission = assignment.submission, let group = submission.groupId else { return nil }
                    return (group, submission.groupName ?? "")
                }
                return Dictionary(named, uniquingKeysWith: { first, _ in first })
            },
            submissionFetched: MoodleCourseAPI.live.submissionFetched
        )
    }
}

nonisolated extension DemoMoodleCourses {
    static let bundled: DemoMoodleCourses? = DemoFixture.bundled?.moodle?.courses(in: .shown)

    static let functions = Set([
        MoodleForumService.forumsFunction, MoodleForumService.discussionsFunction,
        MoodleForumService.discussionPostsFunction, MoodleForumService.viewDiscussionFunction,
        MoodleCourseMembersService.membersFunction, MoodleGradeService.gradeItemsFunction,
        MoodleCourseSummaryService.coursesFunction, MoodleAssignmentService.commentsFunction,
        MoodleAssignmentService.groupsFunction, MoodleCourseContentsService.contentsFunction,
    ]).union(MoodleCourseContentsService.viewCalls.values.map { $0.function })

    func course(where matches: (Course) -> Bool) -> Course? { courses.first(where: matches) }

    func assignment(_ assignId: Int) -> Assignment? {
        courses.lazy.flatMap(\.assignments).first { $0.id == assignId }
    }

    /// Moodle keeps one announcements forum per course.
    func forums(in courseIds: [Int], unread: (MoodleDiscussion) -> Int) -> [MoodleForum] {
        courses.filter { courseIds.contains($0.moodleId) }.flatMap { course in
            let news = MoodleForum(
                id: course.newsForumId, courseId: course.moodleId, type: "news", name: "", cmid: course.moodleId * 10 + 2,
                discussionCount: course.announcements.count, unreadPostCount: course.announcements.map(unread).reduce(0, +)
            )
            return [news] + course.forums.map { forum in
                MoodleForum(
                    id: forum.id, courseId: course.moodleId, type: "general", name: forum.name, cmid: forum.cmid,
                    discussionCount: forum.discussions.count, unreadPostCount: forum.discussions.map(unread).reduce(0, +),
                    intro: forum.intro
                )
            }
        }
    }
}
