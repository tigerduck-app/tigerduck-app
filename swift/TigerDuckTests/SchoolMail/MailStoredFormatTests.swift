#if os(iOS)
import Foundation
import SQLite3
import Testing
@testable import TigerDuck

/// Cache and search index files in the layout released versions write read back, and what the app
/// writes keeps that layout, so an upgrade keeps the mail it already downloaded.
struct MailStoredFormatTests {
    static let account = "B10000000"

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailStoredFormatTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aCachedPageInTheStoredLayoutReadsBackAndIsWrittenTheSameWay() throws {
        let directory = try Self.directory()
        let cache = MailCache(directory: directory, account: { Self.account })
        let url = directory.appendingPathComponent("pages/494e424f58.json")
        #expect(cache.pageURL(folder: "INBOX") == url)
        let stored = #"""
        {"version":1,"account":"B10000000","payload":{"folder":"INBOX","uidValidity":7,"messageCount":1,\#
        "uidNext":43,"fetchedAt":800000000,"summaries":[{"uid":42,"subject":"Exam","fromAddress":\#
        "office@mail.ntust.edu.tw","isSeen":true,"isAnswered":false,"isDeleted":false,\#
        "hasAttachments":false,"isExternal":false}]}}
        """#
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(stored.utf8).write(to: url)

        let page = try #require(cache.loadPage(folder: "INBOX"))
        #expect(page.uidValidity == 7)
        #expect(page.uidNext == 43)
        #expect(page.fetchedAt == Date(timeIntervalSinceReferenceDate: 800_000_000))
        #expect(page.summaries.map(\.uid) == [42])
        #expect(page.summaries.first?.subject == "Exam")
        #expect(page.summaries.first?.isSeen == true)

        cache.savePage(page, wipeCount: cache.wipeCount)
        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(Set(written.keys) == ["version", "account", "payload"])
        #expect(written["version"] as? Int == 1)
        #expect(written["account"] as? String == Self.account)
        let payload = try #require(written["payload"] as? [String: Any])
        #expect(payload["folder"] as? String == "INBOX")
        #expect(payload["uidValidity"] as? Int == 7)
        #expect(payload["fetchedAt"] as? Double == 800_000_000)
        let summary = try #require((payload["summaries"] as? [[String: Any]])?.first)
        #expect(summary["uid"] as? Int == 42)
        #expect(summary["isSeen"] as? Bool == true)
    }

    @Test func aSearchIndexInTheStoredLayoutAnswersAndIsWrittenTheSameWay() throws {
        let directory = try Self.directory()
        let url = directory.appendingPathComponent("search-index.sqlite")
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        let stored = """
            CREATE TABLE owner (id TEXT NOT NULL);
            CREATE TABLE folders (name TEXT PRIMARY KEY NOT NULL, uid_validity INTEGER NOT NULL);
            CREATE TABLE mail (folder TEXT NOT NULL, uid INTEGER NOT NULL, text TEXT NOT NULL,
                               PRIMARY KEY (folder, uid)) WITHOUT ROWID;
            PRAGMA user_version = 1;
            INSERT INTO owner (id) VALUES ('B10000000');
            INSERT INTO folders (name, uid_validity) VALUES ('INBOX', 7);
            INSERT INTO mail (folder, uid, text) VALUES
                ('INBOX', 41, 'office@mail.ntust.edu.tw lunch menu'),
                ('INBOX', 42, 'office@mail.ntust.edu.tw final exam in room 302');
            """
        #expect(sqlite3_exec(db, stored, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let cache = MailCache(directory: directory, account: { Self.account })
        let found = cache.searchIndex.search(folder: "INBOX", query: "Room 302")
        #expect(found?.uidValidity == 7)
        #expect(found?.uids == [42])

        let index = cache.searchIndex
        #expect(index.prepare(folder: "INBOX", uidValidity: 7, onServer: [41, 42, 43], wipeCount: cache.wipeCount) != nil)
        #expect(index.add([43: "Library Hours"], folder: "INBOX", uidValidity: 7, wipeCount: cache.wipeCount))
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var version: Int64 = 0
        var text: String?
        var statement: OpaquePointer?
        try #require(sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
        if sqlite3_step(statement) == SQLITE_ROW { version = sqlite3_column_int64(statement, 0) }
        sqlite3_finalize(statement)
        try #require(sqlite3_prepare_v2(db, "SELECT text FROM mail WHERE folder = 'INBOX' AND uid = 43", -1, &statement, nil) == SQLITE_OK)
        if sqlite3_step(statement) == SQLITE_ROW { text = sqlite3_column_text(statement, 0).map { String(cString: $0) } }
        sqlite3_finalize(statement)
        #expect(version == 1)
        #expect(text == "library hours")
    }
}
#endif
