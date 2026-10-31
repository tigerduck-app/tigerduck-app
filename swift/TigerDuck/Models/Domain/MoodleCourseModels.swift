import Foundation

nonisolated struct MoodleForum: Codable, Sendable, Hashable, Identifiable {
    let id: Int
    let courseId: Int
    let type: String
    let name: String
    let cmid: Int
    var discussionCount: Int
    var unreadPostCount: Int
    var intro: String? = nil

    var isNews: Bool { type == "news" }
}

nonisolated struct MoodleDiscussion: Codable, Sendable, Hashable, Identifiable {
    let id: Int
    let postId: Int
    let title: String
    let message: String
    let preview: String
    let created: Date
    let modified: Date
    let isPinned: Bool
    var unreadCount: Int
    let replyCount: Int
    let authorName: String?
    let attachments: [MoodleFile]
    var authorId: Int? = nil
}

nonisolated struct MoodlePost: Codable, Sendable, Hashable, Identifiable {
    let id: Int
    let parentId: Int?
    let subject: String
    let message: String
    let created: Date?
    let authorName: String?
    let attachments: [MoodleFile]
    var isUnread: Bool
    let isDeleted: Bool
}

nonisolated struct MoodleFile: Codable, Sendable, Hashable {
    let name: String
    let size: Int
    let url: String
    let mimeType: String?
    let modified: Date?
    var path: String? = nil
}

nonisolated struct MoodleCourseMaterials: Codable, Sendable, Equatable {
    var sections: [MoodleMaterialSection]

    var count: Int {
        sections.reduce(0) { total, section in section.materials.reduce(total) { $0 + $1.count } }
    }
}

nonisolated struct MoodleMaterialSection: Codable, Sendable, Hashable, Identifiable {
    let id: Int
    let name: String
    let materials: [MoodleMaterial]
    /// Moodle's section number, 0 for the general section; optional so materials cached without it still load.
    var number: Int? = nil
}

nonisolated struct MoodleMaterial: Codable, Sendable, Hashable, Identifiable {
    enum Content: Codable, Sendable, Hashable {
        case file(MoodleFile)
        case folder([MoodleFile])
        case link(URL)
    }

    let id: Int
    let instance: Int
    let module: String
    let name: String
    let content: Content

    var count: Int {
        switch content {
        case .file, .link: 1
        case .folder(let files): files.count
        }
    }
}

nonisolated struct MoodleGradeItem: Codable, Sendable, Hashable, Identifiable {
    let id: Int
    let name: String
    let type: String
    let module: String?
    let cmid: Int?
    let grade: String?
    let maxGrade: Double?
    let isHidden: Bool
    let feedback: String

    var isCourseTotal: Bool { type == "course" }
    var isCategoryTotal: Bool { type == "category" }
    var isShown: Bool { grade != nil && !isHidden }
}

nonisolated struct MoodleCourseSummary: Codable, Sendable, Equatable {
    let html: String
    let text: String
    let names: [String]
    /// The course format, such as `weeks` or `topics`, and its start date, which find the current week.
    var format: String? = nil
    var startDate: Date? = nil

    static let empty = MoodleCourseSummary(html: "", text: "", names: [])

    func isWorthShowing(besides codes: [String]) -> Bool {
        guard text.contains(where: \.isLetter) else { return false }
        let summary = Self.comparable(text)
        return !(names + codes).contains { Self.comparable($0) == summary }
    }

    private static func comparable(_ text: String) -> String {
        text.filter { !$0.isWhitespace }.lowercased()
    }
}

nonisolated struct MoodleMember: Codable, Sendable, Hashable, Identifiable {
    let id: Int
    let fullName: String
    let idNumber: String?
    let email: String?
    let groups: [String]
    let roles: [Role]
    let pictureURL: URL?
    let description: String
    let interests: [String]
    let fields: [Field]

    nonisolated struct Role: Codable, Sendable, Hashable {
        let shortName: String
        let name: String
        let sortOrder: Int
    }

    nonisolated struct Field: Codable, Sendable, Hashable {
        let name: String
        let value: String
    }
}
