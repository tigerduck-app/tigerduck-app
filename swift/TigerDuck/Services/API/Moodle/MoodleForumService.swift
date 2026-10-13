import Foundation

/// A course's forum, from `mod_forum_get_forums_by_courses`. Every course has one `news` forum,
/// which holds its announcements.
nonisolated struct MoodleForum: Codable, Sendable, Hashable, Identifiable {
    let id: Int
    let courseId: Int
    let type: String
    let name: String
    /// The course module, which Moodle's forum page takes as `id`.
    let cmid: Int
    var discussionCount: Int
    var unreadPostCount: Int

    var isNews: Bool { type == "news" }
}

/// A discussion as `mod_forum_get_forum_discussions` lists it: its first post, with the
/// discussion's counts.
nonisolated struct MoodleDiscussion: Codable, Sendable, Hashable, Identifiable {
    /// The discussion, which `mod_forum_view_forum_discussion` and `discuss.php?d=` take.
    let id: Int
    let postId: Int
    let title: String
    /// HTML, already through Moodle's text filters.
    let message: String
    /// The message as one line of text, kept with it so a list does not parse HTML as it draws.
    let preview: String
    let created: Date
    /// The latest post's time.
    let modified: Date
    let isPinned: Bool
    var unreadCount: Int
    let replyCount: Int
    /// Nil where the forum hides authors.
    let authorName: String?
    let attachments: [MoodleFile]
    /// The author's Moodle user, which finds them among the course's members.
    var authorId: Int? = nil
}

/// A file as Moodle's `external_files` lists it.
nonisolated struct MoodleFile: Codable, Sendable, Hashable {
    let name: String
    let size: Int
    let url: String
    let mimeType: String?
    let modified: Date?
}

/// The forum calls of Moodle's mobile web service. Every call takes the token, so the caller runs
/// it inside `MoodleWebserviceClient.withToken`.
nonisolated enum MoodleForumService {
    static let forumsFunction = "mod_forum_get_forums_by_courses"
    static let discussionsFunction = "mod_forum_get_forum_discussions"
    static let viewDiscussionFunction = "mod_forum_view_forum_discussion"

    /// Asked for explicitly: Moodle's default `perpage` of 0 returns every discussion at once.
    static let discussionsPerPage = 20

    static func forums(
        courseIds: [Int],
        token: String,
        session: URLSession = MoodleWebserviceClient.session,
        siteURL: URL = AppConstants.moodleBaseURL
    ) async throws -> [MoodleForum] {
        try await MoodleWebserviceClient.call(
            forumsFunction,
            params: courseIds.enumerated().map { ("courseids[\($0.offset)]", String($0.element)) },
            token: token,
            as: [RawForum].self,
            session: session,
            siteURL: siteURL
        ).map(\.model)
    }

    /// `page` counts from 0. `moodlewssettingfilter` runs the message through the site's text
    /// filters, as the Moodle app asks for text it shows.
    static func discussions(
        forumId: Int,
        page: Int,
        token: String,
        session: URLSession = MoodleWebserviceClient.session,
        siteURL: URL = AppConstants.moodleBaseURL
    ) async throws -> [MoodleDiscussion] {
        try await MoodleWebserviceClient.call(
            discussionsFunction,
            params: [
                ("forumid", String(forumId)),
                ("page", String(page)),
                ("perpage", String(discussionsPerPage)),
                ("moodlewssettingfilter", "true"),
            ],
            token: token,
            as: RawDiscussions.self,
            session: session,
            siteURL: siteURL
        ).discussions.map(\.model)
    }

    /// Logs the view on Moodle, which marks the discussion read and may count toward completion.
    static func markViewed(
        discussionId: Int,
        token: String,
        session: URLSession = MoodleWebserviceClient.session,
        siteURL: URL = AppConstants.moodleBaseURL
    ) async throws {
        _ = try await MoodleWebserviceClient.call(
            viewDiscussionFunction,
            params: [("discussionid", String(discussionId))],
            token: token,
            as: RawStatus.self,
            session: session,
            siteURL: siteURL
        )
    }
}

// MARK: - Answers

private nonisolated struct RawForum: Decodable, Sendable {
    let id: Int
    let course: Int
    let type: String
    let name: String
    let cmid: Int
    let numdiscussions: Int?
    let unreadpostscount: Int?

    var model: MoodleForum {
        MoodleForum(
            id: id, courseId: course, type: type, name: MoodleHTMLText.plainText(fromHTML: name), cmid: cmid,
            discussionCount: numdiscussions ?? 0, unreadPostCount: unreadpostscount ?? 0
        )
    }
}

private nonisolated struct RawDiscussions: Decodable, Sendable {
    let discussions: [RawDiscussion]
}

private nonisolated struct RawDiscussion: Decodable, Sendable {
    let id: Int
    let discussion: Int
    let name: String
    let message: String
    let created: Int
    let timemodified: Int
    let pinned: Bool
    let numunread: Int?
    let numreplies: Int?
    let userid: Int?
    let userfullname: String?
    let attachments: [RawFile]?

    var model: MoodleDiscussion {
        MoodleDiscussion(
            id: discussion,
            postId: id,
            title: MoodleHTMLText.plainText(fromHTML: name),
            message: message,
            preview: MoodleHTMLText.plainText(fromHTML: message),
            created: Date(timeIntervalSince1970: TimeInterval(created)),
            modified: Date(timeIntervalSince1970: TimeInterval(timemodified)),
            isPinned: pinned,
            unreadCount: numunread ?? 0,
            replyCount: numreplies ?? 0,
            authorName: userfullname,
            attachments: (attachments ?? []).compactMap(\.model),
            authorId: userid
        )
    }
}

private nonisolated struct RawFile: Decodable, Sendable {
    let filename: String?
    let filesize: Int?
    let fileurl: String?
    let mimetype: String?
    let timemodified: Int?

    var model: MoodleFile? {
        guard let filename, let fileurl else { return nil }
        return MoodleFile(
            name: filename,
            size: filesize ?? 0,
            url: fileurl,
            mimeType: mimetype,
            modified: timemodified.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}

private nonisolated struct RawStatus: Decodable, Sendable {
    let status: Bool
}
