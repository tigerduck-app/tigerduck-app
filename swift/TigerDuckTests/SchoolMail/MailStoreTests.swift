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

    /// Never `ValetMailSecretStorage()` — that is the production Keychain service holding the
    /// student's own mail password, and `deleteAll()` here would wipe it. A per-run identifier
    /// keeps the round trip honest (it is a real Keychain) without touching their credentials.
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

    /// A bounce is kept by its display name alone — `fromAddress` is nil, not `""`
    /// (`LiveMailClient.summary`). Both the folder list and the opened-mail body go through
    /// the cache before they are shown again, so if either half dropped the name on the way
    /// back the row would read "(No sender)" the moment the app was reopened, which is the
    /// bug all over again one launch later.
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

    /// The source is cached beside the body, keyed and invalidated the same way, and the two
    /// never land on the same file despite sharing the directory.
    @Test func sourcesRoundTripBesideBodiesAndAreKeyedTheSameWay() {
        let cache = SchoolMailTestDoubles.temporaryCache()
        defer { cache.clearAll() }
        let detail = MailMessageDetail(summary: SchoolMailTestDoubles.summary(uid: 2), messageID: nil, inReplyTo: nil,
                                       references: nil, parts: [], textBody: "body", htmlBody: nil, inlineImages: nil)
        cache.saveDetail(detail, folder: "INBOX", uidValidity: 7)
        cache.saveSource("Subject: x\r\n\r\nraw", folder: "INBOX", uidValidity: 7, uid: 2)

        #expect(cache.loadSource(folder: "INBOX", uidValidity: 7, uid: 2) == "Subject: x\r\n\r\nraw")
        #expect(cache.loadDetail(folder: "INBOX", uidValidity: 7, uid: 2)?.textBody == "body")
        // A new UIDVALIDITY generation means a different mail under the same UID.
        #expect(cache.loadSource(folder: "INBOX", uidValidity: 8, uid: 2) == nil)
        #expect(cache.loadSource(folder: "INBOX", uidValidity: 7, uid: 3) == nil)

        cache.dropFolder("INBOX")
        #expect(cache.loadSource(folder: "INBOX", uidValidity: 7, uid: 2) == nil)
    }

    /// The bug the size check exists for: `saveSource` used to write first and let `pruneBodies`
    /// tidy up, so one 28 MB bounce sorted newest, evicted every other cached body to get under
    /// the limit, and was then evicted itself — the whole cache wiped, nothing gained, on every
    /// visit. Anything over half the shared budget is now never written at all.
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

    /// `saveDetail` has the identical exposure — a body carrying large inline images — so it
    /// takes the identical guard, not just the source path.
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

    /// Sign out, kill the app before the (detached) wipe finishes, sign in as someone else:
    /// nothing in the envelope, the filename or the payload used to say whose mail this was, so
    /// the next student's first paint was the previous student's INBOX — and on a colliding
    /// UIDVALIDITY the two got merged and written back rather than dropped.
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
        // Deleted on the mismatching read, not merely hidden — so it cannot be merged later.
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
