#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

struct MailStoreTests {
    private static func isolatedPreferences() -> (prefs: DefaultsMailPreferences, cleanup: () -> Void) {
        let suiteName = "MailStoreTests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        return (DefaultsMailPreferences(defaults: suite), { suite.removePersistentDomain(forName: suiteName) })
    }

    @Test func credentialsRoundTripAndClear() throws {
        let store = MailCredentialStore(storage: InMemoryMailSecretStorage())
        #expect(store.password() == nil)
        try store.savePassword("secret")
        #expect(store.password() == "secret")
        store.clear()
        #expect(store.password() == nil)
    }

    @Test func valetStorageRoundTrips() throws {
        let storage = ValetMailSecretStorage(identifier: "org.ntust.app.TigerDuck.mail.tests.\(UUID().uuidString)")
        defer { storage.deleteAll() }
        try storage.save("value", forKey: "school_mail_test_key")
        #expect(storage.load(forKey: "school_mail_test_key") == "value")
        storage.delete(forKey: "school_mail_test_key")
        #expect(storage.load(forKey: "school_mail_test_key") == nil)
    }

    @Test func defaultsPreferencesRoundTripAndReset() {
        let (prefs, cleanup) = Self.isolatedPreferences()
        defer { cleanup() }
        prefs.studentID = "B10000000"
        prefs.inboxUIDValidity = 1_722_230_694
        prefs.inboxNextUID = 3976
        prefs.diagnostics = [MailCheckRecord(date: Date(timeIntervalSince1970: 0), trigger: "foreground", result: "no new mail")]
        prefs.notificationsEnabled = false
        #expect(prefs.studentID == "B10000000")
        #expect(prefs.inboxUIDValidity == 1_722_230_694)
        #expect(prefs.inboxNextUID == 3976)
        #expect(prefs.diagnostics.count == 1)
        prefs.reset()
        #expect(prefs.studentID == nil)
        #expect(prefs.inboxNextUID == nil)
        #expect(prefs.notificationsEnabled)
        #expect(prefs.diagnostics.isEmpty)
    }

    @Test func ownedDeletedRoundTripsThroughDefaultsAndClearsOnReset() {
        let (prefs, cleanup) = Self.isolatedPreferences()
        defer { cleanup() }
        #expect(prefs.ownedDeleted(folder: "INBOX", uidValidity: 7).uids.isEmpty)
        prefs.setOwnedDeleted(OwnedDeleted(folder: "INBOX", uidValidity: 7, uids: [3, 1]))
        #expect(prefs.ownedDeleted(folder: "INBOX", uidValidity: 7) == OwnedDeleted(folder: "INBOX", uidValidity: 7, uids: [1, 3]))
        prefs.reset()
        #expect(prefs.ownedDeleted(folder: "INBOX", uidValidity: 7).uids.isEmpty)
    }

    @Test func ownedDeletedReturnsEmptyOnValidityMismatch() {
        let (prefs, cleanup) = Self.isolatedPreferences()
        defer { cleanup() }
        prefs.setOwnedDeleted(OwnedDeleted(folder: "INBOX", uidValidity: 7, uids: [1, 2]))
        #expect(prefs.ownedDeleted(folder: "INBOX", uidValidity: 8).uids.isEmpty)
    }

    @Test func ownedDeletedReplacesAnyEntryForTheSameFolderAcrossValidities() {
        let (prefs, cleanup) = Self.isolatedPreferences()
        defer { cleanup() }
        prefs.setOwnedDeleted(OwnedDeleted(folder: "INBOX", uidValidity: 7, uids: [1, 2]))
        prefs.setOwnedDeleted(OwnedDeleted(folder: "INBOX", uidValidity: 8, uids: [5]))
        #expect(prefs.ownedDeleted(folder: "INBOX", uidValidity: 7).uids.isEmpty)
        #expect(prefs.ownedDeleted(folder: "INBOX", uidValidity: 8).uids == [5])
    }

    @Test func ownedDeletedEmptySetRemovesTheFoldersEntry() {
        let (prefs, cleanup) = Self.isolatedPreferences()
        defer { cleanup() }
        prefs.setOwnedDeleted(OwnedDeleted(folder: "INBOX", uidValidity: 7, uids: [1]))
        prefs.setOwnedDeleted(OwnedDeleted(folder: "INBOX", uidValidity: 7, uids: []))
        #expect(prefs.ownedDeleted(folder: "INBOX", uidValidity: 7).uids.isEmpty)
    }

    @Test func ownedDeletedHandlesFolderNamesWithArbitraryCharacters() {
        let (prefs, cleanup) = Self.isolatedPreferences()
        defer { cleanup() }
        let weird = MailStoreTestFixtures.folderWithArbitraryCharacters
        let other = "a|b"
        prefs.setOwnedDeleted(OwnedDeleted(folder: weird, uidValidity: 3, uids: [9]))
        #expect(prefs.ownedDeleted(folder: weird, uidValidity: 3).uids == [9])
        #expect(prefs.ownedDeleted(folder: other, uidValidity: 3).uids.isEmpty)
    }

    @Test func concurrentSetOwnedDeletedCallsForDifferentFoldersLoseNoEntry() {
        let (prefs, cleanup) = Self.isolatedPreferences()
        defer { cleanup() }
        let folderCount = 200
        DispatchQueue.concurrentPerform(iterations: folderCount) { index in
            prefs.setOwnedDeleted(OwnedDeleted(folder: "folder-\(index)", uidValidity: 1, uids: [UInt32(index)]))
        }
        var lost: [Int] = []
        for index in 0..<folderCount {
            if prefs.ownedDeleted(folder: "folder-\(index)", uidValidity: 1).uids != [UInt32(index)] { lost.append(index) }
        }
        #expect(lost.isEmpty, "lost \(lost.count)/\(folderCount): \(lost.prefix(10))")
    }

    @Test func concurrentSetOwnedDeletedCallsAcrossTwoInstancesLoseNoEntry() {
        let suiteName = "MailStoreTests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let prefsA = DefaultsMailPreferences(defaults: suite)
        let prefsB = DefaultsMailPreferences(defaults: suite)
        let folderCount = 200
        DispatchQueue.concurrentPerform(iterations: folderCount) { index in
            let prefs = index.isMultiple(of: 2) ? prefsA : prefsB
            prefs.setOwnedDeleted(OwnedDeleted(folder: "folder-\(index)", uidValidity: 1, uids: [UInt32(index)]))
        }
        var lost: [Int] = []
        for index in 0..<folderCount {
            if prefsA.ownedDeleted(folder: "folder-\(index)", uidValidity: 1).uids != [UInt32(index)] { lost.append(index) }
        }
        #expect(lost.isEmpty, "lost \(lost.count)/\(folderCount): \(lost.prefix(10))")
    }

    @Test func inMemoryOwnedDeletedMatchesTheSameContract() {
        let prefs = InMemoryMailPreferences()
        #expect(prefs.ownedDeleted(folder: "INBOX", uidValidity: 7).uids.isEmpty)
        prefs.setOwnedDeleted(OwnedDeleted(folder: "INBOX", uidValidity: 7, uids: [3, 1]))
        #expect(prefs.ownedDeleted(folder: "INBOX", uidValidity: 7).uids == [1, 3])
        #expect(prefs.ownedDeleted(folder: "INBOX", uidValidity: 8).uids.isEmpty)
        prefs.setOwnedDeleted(OwnedDeleted(folder: "INBOX", uidValidity: 8, uids: [5]))
        #expect(prefs.ownedDeleted(folder: "INBOX", uidValidity: 7).uids.isEmpty)
        prefs.setOwnedDeleted(OwnedDeleted(folder: "INBOX", uidValidity: 8, uids: []))
        #expect(prefs.ownedDeleted(folder: "INBOX", uidValidity: 8).uids.isEmpty)
        let weird = MailStoreTestFixtures.folderWithArbitraryCharacters
        prefs.setOwnedDeleted(OwnedDeleted(folder: weird, uidValidity: 3, uids: [9]))
        #expect(prefs.ownedDeleted(folder: weird, uidValidity: 3).uids == [9])
        prefs.reset()
        #expect(prefs.ownedDeleted(folder: weird, uidValidity: 3).uids.isEmpty)
    }

    @Test func pagesAndDetailsRoundTrip() {
        let cache = SchoolMailTestDoubles.temporaryCache()
        defer { cache.clearAll() }
        let page = MailFolderPage(folder: "&W8RO9lCZTv1TIw-", uidValidity: 7, messageCount: 2,
                                  summaries: [SchoolMailTestDoubles.summary(uid: 2), SchoolMailTestDoubles.summary(uid: 1)],
                                  oldestLoadedSequence: nil)
        cache.savePage(page)
        #expect(cache.loadPage(folder: "&W8RO9lCZTv1TIw-")?.summaries.map(\.uid) == [2, 1])

        let detail = MailMessageDetail(summary: SchoolMailTestDoubles.summary(uid: 2), messageID: "<a@b>", inReplyTo: nil,
                                       references: nil, parts: [], textBody: "你好", htmlBody: nil, inlineImages: nil)
        cache.saveDetail(detail, folder: "INBOX", uidValidity: 7)
        #expect(cache.loadDetail(folder: "INBOX", uidValidity: 7, uid: 2)?.textBody == "你好")
        #expect(cache.loadDetail(folder: "INBOX", uidValidity: 8, uid: 2) == nil)
    }

    @Test func aSenderWithOnlyADisplayNameSurvivesTheCache() {
        let cache = SchoolMailTestDoubles.temporaryCache()
        defer { cache.clearAll() }
        var bounce = SchoolMailTestDoubles.summary(uid: 9)
        bounce.fromName = "Mail Deliver System"
        bounce.fromAddress = nil
        bounce.subject = "Returned Mail: Hostname cannot be resolved"
        bounce.isExternal = false

        cache.savePage(MailFolderPage(folder: "INBOX", uidValidity: 7, messageCount: 1,
                                      summaries: [bounce], oldestLoadedSequence: nil))
        let reloaded = cache.loadPage(folder: "INBOX")?.summaries.first
        #expect(reloaded?.fromName == "Mail Deliver System")
        #expect(reloaded?.fromAddress == nil)
        #expect(reloaded?.isExternal == false)

        let detail = MailMessageDetail(summary: bounce, messageID: nil, inReplyTo: nil, references: nil,
                                       parts: [], textBody: "delivery errors", htmlBody: nil, inlineImages: nil)
        cache.saveDetail(detail, folder: "INBOX", uidValidity: 7)
        #expect(cache.loadDetail(folder: "INBOX", uidValidity: 7, uid: 9)?.summary.fromName == "Mail Deliver System")
        #expect(cache.loadDetail(folder: "INBOX", uidValidity: 7, uid: 9)?.summary.fromAddress == nil)
    }

    @Test func unreadableFilesAreDeleted() throws {
        let cache = SchoolMailTestDoubles.temporaryCache()
        defer { cache.clearAll() }
        cache.savePage(MailFolderPage(folder: "INBOX", uidValidity: 1, messageCount: 0, summaries: [], oldestLoadedSequence: nil))
        let url = cache.pageURL(folder: "INBOX")
        try Data("{\"version\":999,\"payload\":{}}".utf8).write(to: url)
        #expect(cache.loadPage(folder: "INBOX") == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func bodyCacheStaysUnderItsLimit() async throws {
        let cache = SchoolMailTestDoubles.temporaryCache(bodyLimitBytes: 2_000)
        defer { cache.clearAll() }
        for uid in UInt32(1)...5 {
            let detail = MailMessageDetail(summary: SchoolMailTestDoubles.summary(uid: uid), messageID: nil, inReplyTo: nil,
                                           references: nil, parts: [], textBody: String(repeating: "x", count: 600),
                                           htmlBody: nil, inlineImages: nil)
            cache.saveDetail(detail, folder: "INBOX", uidValidity: 1)
            let saved = Date()
            try await waitUntil { Date() > saved }
        }
        #expect(cache.bodyBytes() <= 2_000)
        #expect(cache.loadDetail(folder: "INBOX", uidValidity: 1, uid: 5) != nil)
        #expect(cache.loadDetail(folder: "INBOX", uidValidity: 1, uid: 1) == nil)
    }

    @Test func sourcesRoundTripBesideBodiesAndAreKeyedTheSameWay() {
        let cache = SchoolMailTestDoubles.temporaryCache()
        defer { cache.clearAll() }
        let detail = MailMessageDetail(summary: SchoolMailTestDoubles.summary(uid: 2), messageID: nil, inReplyTo: nil,
                                       references: nil, parts: [], textBody: "body", htmlBody: nil, inlineImages: nil)
        cache.saveDetail(detail, folder: "INBOX", uidValidity: 7)
        cache.saveSource("Subject: x\r\n\r\nraw", folder: "INBOX", uidValidity: 7, uid: 2)

        #expect(cache.loadSource(folder: "INBOX", uidValidity: 7, uid: 2) == "Subject: x\r\n\r\nraw")
        #expect(cache.loadDetail(folder: "INBOX", uidValidity: 7, uid: 2)?.textBody == "body")
        #expect(cache.loadSource(folder: "INBOX", uidValidity: 8, uid: 2) == nil)
        #expect(cache.loadSource(folder: "INBOX", uidValidity: 7, uid: 3) == nil)

        cache.dropFolder("INBOX")
        #expect(cache.loadSource(folder: "INBOX", uidValidity: 7, uid: 2) == nil)
    }

    @Test func anOversizedSourceIsNotCachedAndLeavesTheCacheAlone() {
        let cache = SchoolMailTestDoubles.temporaryCache(bodyLimitBytes: 4_000)
        defer { cache.clearAll() }
        let detail = MailMessageDetail(summary: SchoolMailTestDoubles.summary(uid: 1), messageID: nil, inReplyTo: nil,
                                       references: nil, parts: [], textBody: "keep me", htmlBody: nil, inlineImages: nil)
        cache.saveDetail(detail, folder: "INBOX", uidValidity: 1)
        let before = cache.bodyBytes()

        cache.saveSource(String(repeating: "s", count: 5_000), folder: "INBOX", uidValidity: 1, uid: 2)
        #expect(cache.loadSource(folder: "INBOX", uidValidity: 1, uid: 2) == nil)
        #expect(cache.loadDetail(folder: "INBOX", uidValidity: 1, uid: 1)?.textBody == "keep me")
        #expect(cache.bodyBytes() == before)
    }

    @Test func anOversizedBodyIsNotCachedEither() {
        let cache = SchoolMailTestDoubles.temporaryCache(bodyLimitBytes: 4_000)
        defer { cache.clearAll() }
        cache.saveSource("small source", folder: "INBOX", uidValidity: 1, uid: 1)
        let huge = MailMessageDetail(summary: SchoolMailTestDoubles.summary(uid: 2), messageID: nil, inReplyTo: nil,
                                     references: nil, parts: [], textBody: String(repeating: "x", count: 5_000),
                                     htmlBody: nil, inlineImages: nil)
        cache.saveDetail(huge, folder: "INBOX", uidValidity: 1)
        #expect(cache.loadDetail(folder: "INBOX", uidValidity: 1, uid: 2) == nil)
        #expect(cache.loadSource(folder: "INBOX", uidValidity: 1, uid: 1) == "small source")
    }

    @Test func aSaveUnderACountFromBeforeAWipeWritesNothing() {
        let cache = SchoolMailTestDoubles.temporaryCache()
        defer { cache.clearAll() }
        let page = MailFolderPage(folder: "INBOX", uidValidity: 1, messageCount: 1,
                                  summaries: [SchoolMailTestDoubles.summary(uid: 2)], oldestLoadedSequence: nil)
        let detail = MailMessageDetail(summary: SchoolMailTestDoubles.summary(uid: 2), messageID: nil, inReplyTo: nil,
                                       references: nil, parts: [], textBody: "body", htmlBody: nil, inlineImages: nil)
        let save = { (count: Int) in
            cache.savePage(page, wipeCount: count)
            cache.saveDetail(detail, folder: "INBOX", uidValidity: 1, wipeCount: count)
            cache.saveSource("source", folder: "INBOX", uidValidity: 1, uid: 2, wipeCount: count)
        }
        let before = cache.wipeCount
        cache.clearAll()

        save(before)
        #expect(cache.loadPage(folder: "INBOX") == nil)
        #expect(cache.loadDetail(folder: "INBOX", uidValidity: 1, uid: 2) == nil)
        #expect(cache.loadSource(folder: "INBOX", uidValidity: 1, uid: 2) == nil)

        save(cache.wipeCount)
        #expect(cache.loadPage(folder: "INBOX")?.summaries.count == 1)
        #expect(cache.loadDetail(folder: "INBOX", uidValidity: 1, uid: 2)?.textBody == "body")
        #expect(cache.loadSource(folder: "INBOX", uidValidity: 1, uid: 2) == "source")
    }

    @Test func clearAllRemovesPagesBodiesAndTemporaryFiles() throws {
        let cache = SchoolMailTestDoubles.temporaryCache()
        cache.savePage(MailFolderPage(folder: "INBOX", uidValidity: 1, messageCount: 0, summaries: [], oldestLoadedSequence: nil))
        let temp = try cache.temporaryFileURL(filename: "課程.pdf")
        try Data("x".utf8).write(to: temp)
        #expect(temp.lastPathComponent == "課程.pdf")
        cache.clearAll()
        #expect(cache.loadPage(folder: "INBOX") == nil)
        #expect(!FileManager.default.fileExists(atPath: temp.path))
    }

    @Test("an attachment that finishes after a wipe writes no file")
    func anAttachmentAfterAWipeWritesNothing() throws {
        let cache = SchoolMailTestDoubles.temporaryCache()
        defer { cache.clearAll() }
        let before = cache.wipeCount
        cache.clearAll()

        #expect(try cache.saveAttachment(Data("x".utf8), filename: "old.pdf", wipeCount: before) == nil)
        #expect(cache.totalBytes() == 0)

        let saved = try #require(try cache.saveAttachment(Data("x".utf8), filename: "new.pdf", wipeCount: cache.wipeCount))
        #expect(FileManager.default.fileExists(atPath: saved.path))
    }

    @Test func openingAnAttachmentDeletesTheOnesOpenedOverADayAgo() throws {
        let cache = SchoolMailTestDoubles.temporaryCache()
        defer { cache.clearAll() }
        let old = try cache.temporaryFileURL(filename: "old.pdf")
        try Data("old".utf8).write(to: old)
        let recent = try cache.temporaryFileURL(filename: "recent.pdf")
        try Data("recent".utf8).write(to: recent)
        let dayAgo = Date().addingTimeInterval(-MailConstants.openedAttachmentLifetime - 60)
        try FileManager.default.setAttributes([.modificationDate: dayAgo], ofItemAtPath: old.deletingLastPathComponent().path)

        let fresh = try cache.temporaryFileURL(filename: "fresh.pdf")

        #expect(!FileManager.default.fileExists(atPath: old.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
        #expect(FileManager.default.fileExists(atPath: fresh.deletingLastPathComponent().path))
    }

    /// A server-supplied filename of just `.` or `..` would otherwise make
    /// `appendingPathComponent` resolve up out of the fresh per-attachment UUID folder this call
    /// creates: `.` back into `attachments/`, `..` one level above that.
    @Test func temporaryFileURLMapsDotDotDotAndEmptyNamesToAttachment() throws {
        let cache = SchoolMailTestDoubles.temporaryCache()
        defer { cache.clearAll() }
        for name in [".", "..", ""] {
            let url = try cache.temporaryFileURL(filename: name)
            #expect(url.lastPathComponent == "attachment")
        }
        let slashed = try cache.temporaryFileURL(filename: "a/b")
        #expect(slashed.lastPathComponent == "a_b")
    }

    @Test func droppingAFolderKeepsTheOthers() {
        let cache = SchoolMailTestDoubles.temporaryCache()
        defer { cache.clearAll() }
        for folder in ["INBOX", "&Vt5lNntS-"] {
            cache.savePage(MailFolderPage(folder: folder, uidValidity: 1, messageCount: 0, summaries: [], oldestLoadedSequence: nil))
        }
        cache.dropFolder("INBOX")
        #expect(cache.loadPage(folder: "INBOX") == nil)
        #expect(cache.loadPage(folder: "&Vt5lNntS-") != nil)
    }

    @Test func aPageCachedForOneStudentIsNotReadBackForAnother() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailStoreTests-\(UUID().uuidString)", isDirectory: true)
        let page = MailFolderPage(folder: "INBOX", uidValidity: 1, messageCount: 1,
                                  summaries: [SchoolMailTestDoubles.summary(uid: 9)], oldestLoadedSequence: nil)
        let first = MailCache(directory: directory, account: { "B10000001" })
        defer { first.clearAll() }
        first.savePage(page)
        #expect(first.loadPage(folder: "INBOX")?.summaries.count == 1)

        let second = MailCache(directory: directory, account: { "B10000002" })
        #expect(second.loadPage(folder: "INBOX") == nil)
        #expect(first.loadPage(folder: "INBOX") == nil)
    }

    @Test func aCachedBodyIsAlsoKeyedToItsAccount() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailStoreTests-\(UUID().uuidString)", isDirectory: true)
        let detail = MailMessageDetail(summary: SchoolMailTestDoubles.summary(uid: 9), messageID: nil,
                                       inReplyTo: nil, references: nil, parts: [], textBody: "secret",
                                       htmlBody: nil, inlineImages: nil)
        let first = MailCache(directory: directory, account: { "B10000001" })
        defer { first.clearAll() }
        first.saveDetail(detail, folder: "INBOX", uidValidity: 1)
        #expect(first.loadDetail(folder: "INBOX", uidValidity: 1, uid: 9)?.textBody == "secret")

        let second = MailCache(directory: directory, account: { "B10000002" })
        #expect(second.loadDetail(folder: "INBOX", uidValidity: 1, uid: 9) == nil)
    }
}
#endif
