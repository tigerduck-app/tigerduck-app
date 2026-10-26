#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

struct MailSearchIndexTests {
    final class Account: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        init(_ value: String?) { self.value = value }
        var current: String? {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    static func cache(account: Account = Account("B10000000")) -> MailCache {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailSearchIndexTests-\(UUID().uuidString)", isDirectory: true)
        return MailCache(directory: directory, account: { account.current })
    }

    static func text(subject: String, body: String?, name: String? = nil, from: String = "office@mail.ntust.edu.tw") -> String {
        var summary = SchoolMailTestDoubles.summary(uid: 1)
        summary.subject = subject
        summary.fromName = name
        summary.fromAddress = from
        return MailSearchIndex.text(of: summary, body: body)
    }

    @discardableResult
    static func fill(_ cache: MailCache, folder: String = "INBOX", uidValidity: UInt32 = 1, _ texts: [UInt32: String]) -> Bool {
        let index = cache.searchIndex
        let held = index.prepare(folder: folder, uidValidity: uidValidity, onServer: Set(texts.keys), wipeCount: cache.wipeCount)
        return held != nil && index.add(texts, folder: folder, uidValidity: uidValidity, wipeCount: cache.wipeCount)
    }

    @Test func findsTheSenderSubjectAndBodyInChineseAndEnglishWhateverTheCase() {
        let cache = Self.cache()
        Self.fill(cache, [
            1: Self.text(subject: "期末考試通知", body: "請於 Room 302 應試", name: "教務處"),
            2: Self.text(subject: "Library Notice", body: "Your book is DUE tomorrow", from: "lib@mail.ntust.edu.tw"),
            3: Self.text(subject: "Café Ünïcode", body: nil),
        ])
        let index = cache.searchIndex
        #expect(index.search(folder: "INBOX", query: "期末")?.uids == [1])
        #expect(index.search(folder: "INBOX", query: "教務處")?.uids == [1])
        #expect(index.search(folder: "INBOX", query: "room 302")?.uids == [1])
        #expect(index.search(folder: "INBOX", query: "due TOMORROW")?.uids == [2])
        #expect(index.search(folder: "INBOX", query: "LIB@MAIL")?.uids == [2])
        #expect(index.search(folder: "INBOX", query: "ünïcode")?.uids == [3])
        #expect(index.search(folder: "INBOX", query: "mail.ntust")?.uids == [3, 2, 1])
        #expect(index.search(folder: "INBOX", query: "畢業")?.uids == [])
        #expect(index.search(folder: "INBOX", query: "100%")?.uids == [])
    }

    @Test func aPhraseBrokenAcrossLinesStillMatches() {
        let cache = Self.cache()
        Self.fill(cache, [1: Self.text(subject: "公告", body: "選課\r\n\t  說明會")])
        #expect(cache.searchIndex.search(folder: "INBOX", query: "選課 說明會")?.uids == [1])
        #expect(cache.searchIndex.search(folder: "INBOX", query: "選課  \n說明會")?.uids == [1])
    }

    @Test func aFolderNeverIndexedHasNoAnswer() {
        let cache = Self.cache()
        Self.fill(cache, [1: Self.text(subject: "公告", body: nil)])
        #expect(cache.searchIndex.search(folder: "Sent", query: "公告") == nil)
    }

    @Test func prepareDropsMailGoneFromTheServerAndKeepsTheRest() {
        let cache = Self.cache()
        Self.fill(cache, [1: Self.text(subject: "公告 1", body: nil), 2: Self.text(subject: "公告 2", body: nil),
                          3: Self.text(subject: "公告 3", body: nil)])
        let held = cache.searchIndex.prepare(folder: "INBOX", uidValidity: 1, onServer: [1, 3, 4], wipeCount: cache.wipeCount)
        #expect(held == [1, 3])
        #expect(cache.searchIndex.search(folder: "INBOX", query: "公告")?.uids == [3, 1])
    }

    @Test func aNewUIDValidityEmptiesTheFolderAndOnlyThatFolder() {
        let cache = Self.cache()
        Self.fill(cache, [1: Self.text(subject: "舊信", body: nil)])
        Self.fill(cache, folder: "Sent", [1: Self.text(subject: "舊信", body: nil)])
        let held = cache.searchIndex.prepare(folder: "INBOX", uidValidity: 2, onServer: [1], wipeCount: cache.wipeCount)
        #expect(held == [])
        #expect(cache.searchIndex.search(folder: "INBOX", query: "舊信")?.uidValidity == 2)
        #expect(cache.searchIndex.search(folder: "INBOX", query: "舊信")?.uids == [])
        #expect(cache.searchIndex.search(folder: "Sent", query: "舊信")?.uids == [1])
    }

    @Test func aWriteUnderAnOldUIDValidityIsRefused() {
        let cache = Self.cache()
        Self.fill(cache, [1: Self.text(subject: "舊信", body: nil)])
        _ = cache.searchIndex.prepare(folder: "INBOX", uidValidity: 2, onServer: [], wipeCount: cache.wipeCount)
        #expect(!cache.searchIndex.add([5: "舊信"], folder: "INBOX", uidValidity: 1, wipeCount: cache.wipeCount))
        #expect(cache.searchIndex.search(folder: "INBOX", query: "舊信")?.uids == [])
    }

    @Test func signingOutDeletesTheIndexAndRefusesTheWritesStillOnTheirWay() {
        let cache = Self.cache()
        Self.fill(cache, [1: Self.text(subject: "成績單", body: nil)])
        let wipeCount = cache.wipeCount
        let file = cache.pageURL(folder: "INBOX").deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("search-index.sqlite")
        #expect(FileManager.default.fileExists(atPath: file.path))

        cache.clearAll()

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(cache.searchIndex.search(folder: "INBOX", query: "成績單") == nil)
        #expect(cache.searchIndex.prepare(folder: "INBOX", uidValidity: 1, onServer: [2], wipeCount: wipeCount) == nil)
        #expect(!cache.searchIndex.add([2: "成績單"], folder: "INBOX", uidValidity: 1, wipeCount: wipeCount))
        #expect(cache.searchIndex.search(folder: "INBOX", query: "成績單") == nil)
    }

    @Test func anotherAccountFindsNothingOfThePreviousOne() {
        let account = Account("B10000000")
        let cache = Self.cache(account: account)
        Self.fill(cache, [1: Self.text(subject: "成績單", body: nil)])

        account.current = "B10000001"

        #expect(cache.searchIndex.search(folder: "INBOX", query: "成績單") == nil)
        #expect(!cache.searchIndex.add([2: "成績單"], folder: "INBOX", uidValidity: 1, wipeCount: cache.wipeCount))
        let held = cache.searchIndex.prepare(folder: "INBOX", uidValidity: 1, onServer: [1], wipeCount: cache.wipeCount)
        #expect(held == [])
        #expect(cache.searchIndex.search(folder: "INBOX", query: "成績單")?.uids == [])
    }

    static func directory(of cache: MailCache) -> URL {
        cache.pageURL(folder: "INBOX").deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test func aFileSQLiteCannotReadIsReplacedByAnEmptyIndex() throws {
        let cache = Self.cache()
        let directory = Self.directory(of: cache)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a database, only bytes".utf8).write(to: directory.appendingPathComponent("search-index.sqlite"))

        #expect(Self.fill(cache, [1: Self.text(subject: "成績單", body: nil)]))
        #expect(cache.searchIndex.search(folder: "INBOX", query: "成績單")?.uids == [1])
    }

    @Test func theIndexIsLeftOutOfBackupsEvenWhenItCreatesTheDirectory() throws {
        let cache = Self.cache()
        Self.fill(cache, [1: Self.text(subject: "成績單", body: nil)])
        cache.clearAll()
        _ = cache.searchIndex.search(folder: "INBOX", query: "成績單")

        let directory = URL(fileURLWithPath: Self.directory(of: cache).path)
        let file = directory.appendingPathComponent("search-index.sqlite")
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func aSearchAskedToStopEndsMidScanWithNoAnswer() {
        final class Count: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() { lock.withLock { value += 1 } }
            var total: Int { lock.withLock { value } }
        }
        let cache = Self.cache()
        let texts = Dictionary(uniqueKeysWithValues: (UInt32(1)...2_000).map {
            ($0, Self.text(subject: "公告 \($0)", body: String(repeating: "內文", count: 50)))
        })
        Self.fill(cache, texts)
        let checks = Count()

        let stopped = cache.searchIndex.search(folder: "INBOX", query: "找不到", shouldStop: {
            checks.increment()
            return true
        })

        #expect(stopped == nil)
        #expect(checks.total == 1)
        #expect(cache.searchIndex.search(folder: "INBOX", query: "公告 1999", shouldStop: { false })?.uids == [1999])
    }

    @Test func aSearchDuringTheWipeWaitsUntilTheFileIsDeleted() {
        final class Found: @unchecked Sendable {
            var uids: [UInt32]?
        }
        let cache = Self.cache()
        Self.fill(cache, [1: Self.text(subject: "成績單", body: nil)])
        let index = cache.searchIndex
        let directory = Self.directory(of: cache)
        let found = Found()
        let finished = DispatchSemaphore(value: 0)

        index.close {
            Thread.detachNewThread {
                found.uids = index.search(folder: "INBOX", query: "成績單")?.uids
                finished.signal()
            }
            #expect(finished.wait(timeout: .now() + .milliseconds(200)) == .timedOut)
            try? FileManager.default.removeItem(at: directory)
        }
        finished.wait()

        #expect(found.uids == nil)
    }

    @Test func aTableFoundDamagedInAQueryIsReplacedByAnEmptyIndex() throws {
        let account = Account("B10000000")
        let first = Self.cache(account: account)
        let directory = Self.directory(of: first)
        Self.fill(first, [1: Self.text(subject: "成績單", body: nil)])
        first.searchIndex.close {}
        // The header page still reads; the pages after it, which hold the tables, do not.
        let file = directory.appendingPathComponent("search-index.sqlite")
        var bytes = try Data(contentsOf: file)
        try #require(bytes.count > 4_096)
        bytes.replaceSubrange(4_096..., with: Data(repeating: 0xFF, count: bytes.count - 4_096))
        try bytes.write(to: file)
        let second = MailCache(directory: directory, account: { account.current })

        #expect(second.searchIndex.search(folder: "INBOX", query: "成績單")?.uids == nil)
        #expect(Self.fill(second, [2: Self.text(subject: "選課", body: nil)]))
        #expect(second.searchIndex.search(folder: "INBOX", query: "選課")?.uids == [2])
    }

    @Test func anIndexLetGoClosesItsFile() throws {
        var cache = Optional(Self.cache())
        let directory = try #require(cache.map(Self.directory(of:)))
        Self.fill(try #require(cache), [1: Self.text(subject: "成績單", body: nil)])
        #expect(Self.openFiles(in: directory) > 0)

        cache = nil

        #expect(Self.openFiles(in: directory) == 0)
    }

    /// This process's descriptors open on a file under `directory`.
    static func openFiles(in directory: URL) -> Int {
        (0..<getdtablesize()).filter { descriptor in
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(descriptor, F_GETPATH, &path) != -1 else { return false }
            let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self).contains(directory.lastPathComponent)
        }.count
    }

    @Test func theTextOfAMailIsCappedInLength() {
        let text = Self.text(subject: "長信", body: String(repeating: "字", count: MailSearchIndex.maxTextLength * 2))
        #expect(text.count == MailSearchIndex.maxTextLength)
    }
}
#endif
