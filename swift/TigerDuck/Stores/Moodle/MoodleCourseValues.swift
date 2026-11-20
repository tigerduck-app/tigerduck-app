import Foundation

nonisolated struct MoodleTermForums: Codable, Sendable, Equatable {
    let courseIds: [Int]
    var forums: [MoodleForum]
}

nonisolated struct MoodleDiscussionList: Codable, Sendable, Equatable {
    let forumId: Int
    var discussions: [MoodleDiscussion]
    var pageCount: Int
    var hasMore: Bool

    var sorted: [MoodleDiscussion] { sorted(by: \.created) }

    func sorted(by date: KeyPath<MoodleDiscussion, Date>) -> [MoodleDiscussion] {
        discussions.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            if lhs[keyPath: date] != rhs[keyPath: date] { return lhs[keyPath: date] > rhs[keyPath: date] }
            return lhs.id > rhs.id
        }
    }

    mutating func append(page: [MoodleDiscussion]) {
        let known = Set(discussions.map(\.id))
        discussions += page.filter { !known.contains($0.id) }
        pageCount += 1
        hasMore = page.count == MoodleForumService.discussionsPerPage
    }
}

nonisolated struct MoodleMemberList: Codable, Sendable, Equatable {
    let ownId: Int?
    var members: [MoodleMember]

    /// Whether anyone but the account is there to show, which a course split into groups the
    /// account sees alone of may not have.
    var showsOthers: Bool {
        members.contains { $0.id != ownId }
    }
}

nonisolated struct MoodleDiscussionThread: Codable, Sendable, Equatable {
    let discussionId: Int
    var posts: [MoodlePost]
}

nonisolated struct MoodleCourseGrades: Codable, Sendable, Equatable {
    var items: [MoodleGradeItem]

    var total: MoodleGradeItem? {
        items.first { $0.isCourseTotal && $0.isShown }
    }

    var graded: [MoodleGradeItem] {
        items.filter { !$0.isCourseTotal && !$0.isCategoryTotal && $0.isShown }
    }
}
