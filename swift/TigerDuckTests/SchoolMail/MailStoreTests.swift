#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

struct MailStoreTests {
    /// A `DefaultsMailPreferences` on its own `UserDefaults` suite, torn down by the returned
    /// `cleanup` closure — never the app's real `UserDefaults.standard`. Follows this repo's
    /// existing isolation idiom (`CloudSyncPreferenceTests.withIsolatedKey`,
    /// `ClockCoreTests`'s per-test `UserDefaults(suiteName:)` + `removePersistentDomain`), so
    /// these tests can run concurrently with each other and with any other suite touching
    /// `school_mail_*` keys without interfering.
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
        let storage = ValetMailSecretStorage()
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

    /// Task 9 fix round 1, Important #1: the get→filter→append→set round trip in
    /// `setOwnedDeleted` raced across folders before it was locked — two concurrent calls for
    /// different folders could read the same snapshot and each write back a list missing the
    /// other's entry. `DispatchQueue.concurrentPerform` runs every folder's write from a true OS
    /// thread pool, all against the same `prefs` instance; if any entry goes missing, the lock
    /// isn't doing its job. (Verified this reproduces the loss reliably — 183/200 folders lost —
    /// against a deliberately-unlocked build of `setOwnedDeleted` before restoring the lock.)
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

    /// Task 11 dispatch addition: `MailChecker.shared` and `MailAccountManager.shared` each
    /// construct their own `DefaultsMailPreferences()` instance over the same underlying
    /// `UserDefaults` keys, so the lock guarding `setOwnedDeleted`'s read-modify-write must be
    /// shared across every instance, not just within one — otherwise two instances racing over
    /// the same suite lose entries the same way a single unlocked instance did (see
    /// `concurrentSetOwnedDeletedCallsForDifferentFoldersLoseNoEntry` above).
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

    @Test func unreadableFilesAreDeleted() throws {
        let cache = SchoolMailTestDoubles.temporaryCache()
        defer { cache.clearAll() }
        cache.savePage(MailFolderPage(folder: "INBOX", uidValidity: 1, messageCount: 0, summaries: [], oldestLoadedSequence: nil))
        let url = cache.pageURL(folder: "INBOX")
        try Data("{\"version\":999,\"payload\":{}}".utf8).write(to: url)
        #expect(cache.loadPage(folder: "INBOX") == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func bodyCacheStaysUnderItsLimit() {
        let cache = SchoolMailTestDoubles.temporaryCache(bodyLimitBytes: 2_000)
        defer { cache.clearAll() }
        for uid in UInt32(1)...5 {
            let detail = MailMessageDetail(summary: SchoolMailTestDoubles.summary(uid: uid), messageID: nil, inReplyTo: nil,
                                           references: nil, parts: [], textBody: String(repeating: "x", count: 600),
                                           htmlBody: nil, inlineImages: nil)
            cache.saveDetail(detail, folder: "INBOX", uidValidity: 1)
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(cache.bodyBytes() <= 2_000)
        #expect(cache.loadDetail(folder: "INBOX", uidValidity: 1, uid: 5) != nil)
        #expect(cache.loadDetail(folder: "INBOX", uidValidity: 1, uid: 1) == nil)
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

    /// Task 9 fix round 1, Minor #3: a server-supplied filename of exactly `.` or `..` would
    /// otherwise resolve `appendingPathComponent` up out of the fresh per-attachment UUID folder
    /// this call creates — `.` back into `attachments/`, `..` a level above that.
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
}
#endif
