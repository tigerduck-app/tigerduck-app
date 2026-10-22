import Foundation
import os
import Testing
@testable import TigerDuck

struct MoodleForumServiceTests {
    private static let site = URL(string: "https://moodle-stub.invalid")!

    private static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        return URLSession(configuration: config)
    }

    private static func endpoint(_ function: String, token: String) -> URL {
        URL(string: "https://moodle-stub.invalid/webservice/rest/server.php"
            + "?moodlewsrestformat=json&wsfunction=\(function)&wstoken=\(token)")!
    }

    private static func answer(_ body: String, function: String, token: String) {
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data(body.utf8)), for: endpoint(function, token: token))
    }

    private static func body(of function: String, token: String) throws -> String? {
        let request = try #require(SettingsAPIStub.requests(for: endpoint(function, token: token)).first)
        return SettingsAPIStub.bodyData(from: request).flatMap { String(data: $0, encoding: .utf8) }
    }

    static let forums = #"""
    [
      {"id": 501, "course": 20119, "type": "news", "name": "Announcements &amp; news",
       "intro": "<p>General news and announcements</p>", "introformat": 1, "introfiles": [],
       "assessed": 0, "assesstimestart": 0, "assesstimefinish": 0, "scale": 0, "grade_forum": 0,
       "grade_forum_notify": 0, "maxbytes": 0, "maxattachments": 9, "forcesubscribe": 1, "trackingtype": 1,
       "rsstype": 0, "rssarticles": 0, "timemodified": 1790000000, "warnafter": 0, "blockafter": 0,
       "blockperiod": 0, "completiondiscussions": 0, "completionreplies": 0, "completionposts": 0,
       "cmid": 9001, "numdiscussions": 6, "cancreatediscussions": false, "lockdiscussionafter": 0,
       "istracked": true, "unreadpostscount": 2},
      {"id": 502, "course": 20103, "type": "general", "name": "Q&A", "intro": "", "introformat": 1,
       "assessed": 0, "assesstimestart": 0, "assesstimefinish": 0, "scale": 0, "grade_forum": 0,
       "grade_forum_notify": 0, "maxbytes": 0, "maxattachments": 9, "forcesubscribe": 0, "trackingtype": 1,
       "rsstype": 0, "rssarticles": 0, "timemodified": 1790000000, "warnafter": 0, "blockafter": 0,
       "blockperiod": 0, "completiondiscussions": 0, "completionreplies": 0, "completionposts": 0,
       "cmid": 9002, "numdiscussions": 3, "istracked": false}
    ]
    """#

    static let discussions = #"""
    {"discussions": [
      {"id": 7001, "name": "Midterm scope", "groupid": -1, "timemodified": 1792040000, "usermodified": 3,
       "timestart": 0, "timeend": 0, "discussion": 801, "parent": 0, "userid": 3, "created": 1792030000,
       "modified": 1792030000, "mailed": 1, "subject": "Midterm scope",
       "message": "<p dir=\"ltr\">The midterm is on <strong>11/4</strong>.</p><ul><li>Chapters 1 to 6</li></ul>",
       "messageformat": 1, "messagetrust": 0, "attachment": "1",
       "attachments": [{"filename": "scope.pdf", "filepath": "/", "filesize": 1258291,
         "fileurl": "https://moodle2.ntust.edu.tw/webservice/pluginfile.php/123/mod_forum/attachment/7001/scope.pdf",
         "timemodified": 1792030000, "mimetype": "application/pdf", "isexternalfile": false}],
       "totalscore": 0, "mailnow": 0, "userfullname": "B11399001 @ Tiger Duck",
       "usermodifiedfullname": "B11399001 @ Tiger Duck",
       "userpictureurl": "https://moodle2.ntust.edu.tw/theme/image.php/moove/core/1/u/f2",
       "usermodifiedpictureurl": "https://moodle2.ntust.edu.tw/theme/image.php/moove/core/1/u/f2",
       "numreplies": 0, "numunread": 1, "pinned": true, "locked": false, "starred": false,
       "canreply": false, "canlock": false, "canfavourite": true},
      {"id": 7002, "name": "Week 5 online", "groupid": -1, "timemodified": 1791000000, "usermodified": null,
       "timestart": 0, "timeend": 0, "discussion": 802, "parent": 0, "userid": null, "created": 1791000000,
       "modified": 1791000000, "mailed": 1, "subject": "Week 5 online", "message": "", "messageformat": 1,
       "messagetrust": 0, "attachment": "", "totalscore": 0, "mailnow": 0, "userfullname": null,
       "usermodifiedfullname": null, "userpictureurl": null, "usermodifiedpictureurl": null,
       "numreplies": 2, "numunread": 0, "pinned": false, "locked": false, "starred": false,
       "canreply": false, "canlock": false, "canfavourite": true}
    ], "warnings": []}
    """#

    @Test("forums ask for every course of the term in one call and decode their counts and descriptions")
    func forums() async throws {
        let token = UUID().uuidString
        Self.answer(Self.forums, function: MoodleForumService.forumsFunction, token: token)

        let forums = try await MoodleForumService.forums(
            courseIds: [20119, 20103], token: token, session: Self.session(), siteURL: Self.site
        )

        #expect(try Self.body(of: MoodleForumService.forumsFunction, token: token)
            == "courseids%5B0%5D=20119&courseids%5B1%5D=20103")
        #expect(forums == [
            MoodleForum(id: 501, courseId: 20119, type: "news", name: "Announcements & news", cmid: 9001,
                        discussionCount: 6, unreadPostCount: 2, intro: "General news and announcements"),
            MoodleForum(id: 502, courseId: 20103, type: "general", name: "Q&A", cmid: 9002,
                        discussionCount: 3, unreadPostCount: 0, intro: nil),
        ])
        #expect(forums[0].isNews && !forums[1].isNews)
    }

    @Test("discussions ask for an explicit page of 20, never Moodle's default of every one, with filters on")
    func discussionsRequest() async throws {
        let token = UUID().uuidString
        Self.answer(Self.discussions, function: MoodleForumService.discussionsFunction, token: token)

        _ = try await MoodleForumService.discussions(
            forumId: 501, page: 2, token: token, session: Self.session(), siteURL: Self.site
        )

        #expect(try Self.body(of: MoodleForumService.discussionsFunction, token: token)
            == "forumid=501&page=2&perpage=20&moodlewssettingfilter=true")
    }

    @Test("a discussion decodes its first post, counts, author and attachments, and a hidden author as none")
    func discussionsDecode() async throws {
        let token = UUID().uuidString
        Self.answer(Self.discussions, function: MoodleForumService.discussionsFunction, token: token)

        let discussions = try await MoodleForumService.discussions(
            forumId: 501, page: 0, token: token, session: Self.session(), siteURL: Self.site
        )

        let first = try #require(discussions.first)
        #expect(first.id == 801)
        #expect(first.postId == 7001)
        #expect(first.title == "Midterm scope")
        #expect(first.preview == "The midterm is on 11/4. Chapters 1 to 6")
        #expect(first.created == Date(timeIntervalSince1970: 1_792_030_000))
        #expect(first.modified == Date(timeIntervalSince1970: 1_792_040_000))
        #expect(first.isPinned)
        #expect(first.unreadCount == 1)
        #expect(first.replyCount == 0)
        #expect(first.authorName == "B11399001 @ Tiger Duck")
        #expect(first.authorId == 3)
        #expect(first.attachments == [MoodleFile(
            name: "scope.pdf", size: 1_258_291,
            url: "https://moodle2.ntust.edu.tw/webservice/pluginfile.php/123/mod_forum/attachment/7001/scope.pdf",
            mimeType: "application/pdf", modified: Date(timeIntervalSince1970: 1_792_030_000), path: "/"
        )])

        let second = try #require(discussions.last)
        #expect(second.authorName == nil)
        #expect(second.authorId == nil)
        #expect(second.attachments.isEmpty)
        #expect(second.preview.isEmpty)
        #expect(second.replyCount == 2)
        #expect(!second.isPinned)
    }

    static let posts = #"""
    {"posts": [
      {"id": 7101, "subject": "Lab 1 checksum &amp; pseudo header", "replysubject": "Re: Lab 1 checksum",
       "message": "<p>Which fields does the <strong>UDP</strong> checksum cover?</p>", "messageformat": 1,
       "author": {"id": 3, "fullname": "B11399001 @ Tiger Duck", "isdeleted": false, "groups": [],
                  "urls": {"profile": "https://moodle-stub.invalid/user/view.php?id=3",
                           "profileimage": "https://moodle-stub.invalid/theme/image.php/moove/core/1/u/f1"}},
       "discussionid": 901, "hasparent": false, "parentid": null, "timecreated": 1792030000,
       "timemodified": 1792030000, "unread": true, "isdeleted": false, "isprivatereply": false,
       "haswordcount": false, "wordcount": null, "charcount": null,
       "capabilities": {"view": true, "edit": false, "delete": false, "split": false, "reply": false,
                        "selfenrol": false, "export": false, "controlreadstatus": false, "canreplyprivately": false},
       "urls": {"view": "https://moodle-stub.invalid/mod/forum/discuss.php?d=901#p7101"},
       "attachments": [{"contextid": 55, "component": "mod_forum", "filearea": "attachment", "itemid": 7101,
         "filepath": "/", "filename": "capture.pcapng", "isdir": false, "isimage": false,
         "timemodified": 1792030000, "timecreated": 1792030000, "filesize": 20480, "author": "Tiger Duck",
         "license": "unknown", "filenameshort": "capture.pcapng", "filesizeformatted": "20 KB", "icon": "f/unknown",
         "timecreatedformatted": "", "timemodifiedformatted": "",
         "url": "https://moodle-stub.invalid/pluginfile.php/55/mod_forum/attachment/7101/capture.pcapng?forcedownload=1",
         "urls": {"export": null}, "html": {"plagiarism": null}}],
       "messageinlinefiles": [], "tags": [], "html": {"rating": null, "taglist": null, "authorsubheading": ""}},
      {"id": 7102, "subject": "Re: Lab 1 checksum", "replysubject": "Re: Lab 1 checksum",
       "message": "<p>Source and destination address, a zero, the protocol and the length.</p>", "messageformat": 1,
       "author": {"id": 4, "fullname": "B11399002 @ Duck Tiger", "urls": {}},
       "discussionid": 901, "hasparent": true, "parentid": 7101, "timecreated": 1792032100,
       "timemodified": 1792032100, "unread": false, "isdeleted": false, "isprivatereply": false,
       "haswordcount": false, "capabilities": {}, "attachments": []},
      {"id": 7103, "subject": "This forum post has been removed", "replysubject": "",
       "message": "The content of this forum post has been removed and can no longer be accessed.",
       "messageformat": 1, "author": {"urls": {}}, "discussionid": 901, "hasparent": true, "parentid": 7102,
       "timecreated": null, "timemodified": null, "isdeleted": true, "isprivatereply": false,
       "haswordcount": false, "capabilities": {}, "attachments": []}
    ], "forumid": 502, "courseid": 20119, "ratinginfo": {"contextid": 55, "component": "mod_forum",
     "ratingarea": "post", "canviewall": null, "canviewany": null, "scales": [], "ratings": []}, "warnings": []}
    """#

    @Test("a discussion's posts ask for every post at once, oldest first, with filters on")
    func postsRequest() async throws {
        let token = UUID().uuidString
        Self.answer(Self.posts, function: MoodleForumService.discussionPostsFunction, token: token)

        _ = try await MoodleForumService.posts(discussionId: 901, token: token, session: Self.session(), siteURL: Self.site)

        #expect(try Self.body(of: MoodleForumService.discussionPostsFunction, token: token)
            == "discussionid=901&sortby=created&sortdirection=ASC&moodlewssettingfilter=true")
    }

    @Test("a post decodes its parent, author, time, read state and attachments, and a deleted one Moodle's note")
    func postsDecode() async throws {
        let token = UUID().uuidString
        Self.answer(Self.posts, function: MoodleForumService.discussionPostsFunction, token: token)

        let posts = try await MoodleForumService.posts(
            discussionId: 901, token: token, session: Self.session(), siteURL: Self.site
        )

        #expect(posts.map(\.id) == [7101, 7102, 7103])
        let first = posts[0]
        #expect(first.parentId == nil)
        #expect(first.subject == "Lab 1 checksum & pseudo header")
        #expect(first.message == "<p>Which fields does the <strong>UDP</strong> checksum cover?</p>")
        #expect(first.authorName == "B11399001 @ Tiger Duck")
        #expect(first.created == Date(timeIntervalSince1970: 1_792_030_000))
        #expect(first.isUnread)
        #expect(!first.isDeleted)
        #expect(first.attachments == [MoodleFile(
            name: "capture.pcapng", size: 20480,
            url: "https://moodle-stub.invalid/pluginfile.php/55/mod_forum/attachment/7101/capture.pcapng?forcedownload=1",
            mimeType: nil, modified: Date(timeIntervalSince1970: 1_792_030_000), path: "/"
        )])

        #expect(posts[1].parentId == 7101)
        #expect(!posts[1].isUnread)
        #expect(posts[1].attachments.isEmpty)

        let removed = posts[2]
        #expect(removed.parentId == 7102)
        #expect(removed.isDeleted)
        #expect(removed.authorName == nil)
        #expect(removed.created == nil)
        #expect(!removed.isUnread)
        #expect(removed.message == "The content of this forum post has been removed and can no longer be accessed.")
    }

    @Test("marking a discussion viewed posts its discussion id, not its first post's")
    func markViewed() async throws {
        let token = UUID().uuidString
        Self.answer(#"{"status": true, "warnings": []}"#, function: MoodleForumService.viewDiscussionFunction, token: token)

        try await MoodleForumService.markViewed(discussionId: 801, token: token, session: Self.session(), siteURL: Self.site)

        #expect(try Self.body(of: MoodleForumService.viewDiscussionFunction, token: token) == "discussionid=801")
    }

    enum TokenWait: CaseIterable {
        case stored, renewed
    }

    @Test("a view event waits for a token under its original account", arguments: TokenWait.allCases)
    func invalidatedViewToken(wait: TokenWait) async throws {
        let old = UUID().uuidString
        let replacement = UUID().uuidString
        let current = OSAllocatedUnfairLock(initialState: true)
        let gate = ManualSleeper()
        Self.answer(#"{"errorcode":"invalidtoken","exception":"moodle_exception","message":"Expired"}"#,
                    function: MoodleForumService.viewDiscussionFunction, token: old)
        Self.answer(#"{"status":true,"warnings":[]}"#,
                    function: MoodleForumService.viewDiscussionFunction, token: replacement)
        let tokens = MoodleWebserviceClient.TokenSource(
            stored: {
                if wait == .stored { await gate.sleep(for: .seconds(1)) }
                return wait == .stored ? replacement : old
            },
            renew: { _ in
                await gate.sleep(for: .seconds(1))
                return replacement
            }
        )
        let event = Task {
            try await MoodleCourseAPI.markDiscussionViewed(
                801, isCurrent: { current.withLock { $0 } }, tokens: tokens, session: Self.session(), siteURL: Self.site
            )
        }
        try await gate.waitUntilArmed()
        current.withLock { $0 = false }
        await gate.fire()

        await #expect(throws: CancellationError.self) { try await event.value }
        #expect(SettingsAPIStub.requests(for: Self.endpoint(MoodleForumService.viewDiscussionFunction, token: replacement)).isEmpty)
        #expect(SettingsAPIStub.requests(for: Self.endpoint(MoodleForumService.viewDiscussionFunction, token: old)).count
            == (wait == .stored ? 0 : 1))
    }

    @Test("the view event checks account validity again before an access-error retry")
    func invalidatedViewRetry() async throws {
        let token = UUID().uuidString
        let endpoint = Self.endpoint(MoodleForumService.viewDiscussionFunction, token: token)
        Self.answer(#"{"errorcode":"accessexception","exception":"moodle_exception","message":"Access denied"}"#,
                    function: MoodleForumService.viewDiscussionFunction, token: token)
        Self.answer(#"{"status":true,"warnings":[]}"#,
                    function: MoodleForumService.viewDiscussionFunction, token: token)
        let tokens = MoodleWebserviceClient.TokenSource(stored: { token }, renew: { _ in token })

        await #expect(throws: CancellationError.self) {
            try await MoodleCourseAPI.markDiscussionViewed(
                801, isCurrent: { SettingsAPIStub.requests(for: endpoint).isEmpty },
                tokens: tokens, session: Self.session(), siteURL: Self.site
            )
        }
        #expect(SettingsAPIStub.requests(for: endpoint).count == 1)
    }

    @Test("a current view event sends one request through the same token helper")
    func currentViewToken() async throws {
        let token = UUID().uuidString
        Self.answer(#"{"status":true,"warnings":[]}"#,
                    function: MoodleForumService.viewDiscussionFunction, token: token)
        let tokens = MoodleWebserviceClient.TokenSource(stored: { token }, renew: { _ in token })

        try await MoodleCourseAPI.markDiscussionViewed(
            801, isCurrent: { true }, tokens: tokens, session: Self.session(), siteURL: Self.site
        )

        #expect(SettingsAPIStub.requests(for: Self.endpoint(MoodleForumService.viewDiscussionFunction, token: token)).count == 1)
        #expect(try Self.body(of: MoodleForumService.viewDiscussionFunction, token: token) == "discussionid=801")
    }

    @Test("site info gives the account's user id and the functions the site allows, none when it lists none")
    func siteInfoFunctions() async throws {
        let token = UUID().uuidString
        Self.answer(#"""
        {"sitename": "Moodle", "username": "b11399001", "userid": 42, "siteurl": "https://moodle-stub.invalid",
         "functions": [{"name": "mod_forum_get_forums_by_courses", "version": "2024100700"},
                       {"name": "mod_forum_get_forum_discussions", "version": "2024100700"}],
         "release": "4.5", "version": "2024100700"}
        """#, function: "core_webservice_get_site_info", token: token)
        let bare = UUID().uuidString
        Self.answer(#"{"sitename": "Moodle", "userid": 7}"#, function: "core_webservice_get_site_info", token: bare)

        let info = try await MoodleSiteInfoService.fetchSiteInfo(token: token, session: Self.session(), siteURL: Self.site)
        #expect(info.userId == 42)
        #expect(info.functions == ["mod_forum_get_forums_by_courses", "mod_forum_get_forum_discussions"])

        let bareInfo = try await MoodleSiteInfoService.fetchSiteInfo(token: bare, session: Self.session(), siteURL: Self.site)
        #expect(bareInfo.userId == 7)
        #expect(bareInfo.functions.isEmpty)
    }
}
