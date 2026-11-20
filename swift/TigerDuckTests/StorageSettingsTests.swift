#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

struct StorageSettingsTests {
    /// Stores that report fixed sizes and record which ones were cleared.
    final class Stores: @unchecked Sendable {
        private let lock = NSLock()
        private var sizes: [StorageKind: Int?]
        private var cleared: [StorageKind] = []

        init(_ sizes: [StorageKind: Int?]) { self.sizes = sizes }

        var clears: [StorageKind] { lock.withLock { cleared } }

        var cleaner: StorageCleaner {
            StorageCleaner(stores: Dictionary(uniqueKeysWithValues: StorageKind.allCases.map { kind in
                (kind, StorageCleaner.Store(
                    measure: { self.lock.withLock { self.sizes[kind] ?? nil } },
                    clear: { self.lock.withLock { self.cleared.append(kind); self.sizes[kind] = 0 } }
                ))
            }))
        }
    }

    static let sizes: [StorageKind: Int] = [
        .moodleFiles: 3_000, .moodleData: 200, .mailAttachments: 700, .mailCache: 100, .mail: 2_000,
        .browserDownloads: 5_000, .websiteData: 1_000,
    ]

    @Test func theTotalAddsWhatWasMeasuredAndSkipsWhatWasNot() async {
        let sizes = await Stores([.moodleFiles: 3_000, .mail: 1_000, .websiteData: nil]).cleaner.measure()
        #expect(sizes.bytes == [.moodleFiles: 3_000, .mail: 1_000])
        #expect(sizes.total == 4_000)
    }

    @Test func theBarHasAPartForEachKindAboveZeroInPageOrder() {
        let sizes = StorageSizes(bytes: [.websiteData: 1_000, .browserDownloads: 1_000, .mail: 0, .moodleData: 1_000, .moodleFiles: 1_000])
        #expect(sizes.segments.map(\.kind) == [.moodleFiles, .moodleData, .browserDownloads, .websiteData])
        #expect(sizes.segments.allSatisfy { $0.share == 0.25 })
    }

    @Test func theRowsAreGroupedAsDrawnAndEveryKindHasOne() {
        #expect(StorageKind.sections.map(\.kinds) == [
            [.moodleFiles, .moodleData, .mailAttachments],
            [.mailCache, .mail],
            [.browserDownloads, .websiteData],
        ])
        #expect(StorageKind.sections.flatMap(\.kinds) == StorageKind.allCases)
    }

    @Test func anEmptyOrUnmeasuredPageHasNoBar() {
        #expect(StorageSizes().segments.isEmpty)
        #expect(StorageSizes(bytes: [.moodleFiles: 0, .mail: 0]).segments.isEmpty)
    }

    @Test(arguments: StorageKind.allCases)
    func aDeleteClearsOnlyItsOwnKindThenMeasuresAgain(kind: StorageKind) async {
        let stores = Stores(Self.sizes)
        let sizes = await stores.cleaner.delete(kind)
        #expect(stores.clears == [kind])
        #expect(sizes.bytes[kind] == 0)
        #expect(sizes.total == Self.sizes.values.reduce(0, +) - Self.sizes[kind]!)
    }

    @Test func downloadedMailWebsiteDataAndBrowserDownloadsAskBeforeDeleting() {
        #expect(StorageKind.allCases.filter(\.confirmsDelete) == [.mail, .browserDownloads, .websiteData])
    }

    @Test func eachMailRowMeasuresAndClearsOnlyItsOwnPart() async throws {
        let cache = SchoolMailTestDoubles.temporaryCache()
        defer { cache.clearAll() }
        cache.savePage(MailFolderPage(folder: "INBOX", uidValidity: 1, messageCount: 1,
                                      summaries: [SchoolMailTestDoubles.summary(uid: 1)], oldestLoadedSequence: nil))
        let detail = MailMessageDetail(summary: SchoolMailTestDoubles.summary(uid: 1), messageID: nil, inReplyTo: nil,
                                       references: nil, parts: [], textBody: String(repeating: "x", count: 500),
                                       htmlBody: nil, inlineImages: nil)
        cache.saveDetail(detail, folder: "INBOX", uidValidity: 1)
        cache.saveSource(String(repeating: "s", count: 400), folder: "INBOX", uidValidity: 1, uid: 1)
        let attachment = try cache.temporaryFileURL(filename: "課程.pdf")
        try Data(repeating: 0, count: 700).write(to: attachment)
        let attachments = StorageCleaner.Store.mail(cache, .attachments)
        let lists = StorageCleaner.Store.mail(cache, .lists)
        let messages = StorageCleaner.Store.mail(cache, .messages)
        let total = cache.totalBytes()

        #expect(await attachments.measure() == 700)
        #expect(await messages.measure() == cache.bodyBytes())
        let listBytes = try #require(await lists.measure())
        #expect(listBytes > 0)
        #expect(700 + cache.bodyBytes() + listBytes == total)

        let wipes = cache.wipeCount
        await attachments.clear()
        #expect(!FileManager.default.fileExists(atPath: attachment.path))
        #expect(cache.loadPage(folder: "INBOX") != nil)
        #expect(cache.loadDetail(folder: "INBOX", uidValidity: 1, uid: 1) != nil)

        await lists.clear()
        #expect(cache.loadPage(folder: "INBOX") == nil)
        #expect(cache.loadDetail(folder: "INBOX", uidValidity: 1, uid: 1) != nil)

        await messages.clear()
        #expect(cache.loadDetail(folder: "INBOX", uidValidity: 1, uid: 1) == nil)
        #expect(cache.loadSource(folder: "INBOX", uidValidity: 1, uid: 1) == nil)
        #expect(cache.totalBytes() == 0)
        #expect(cache.wipeCount == wipes + 3)
    }

    @Test func clearingDownloadedMailEmptiesTheSearchIndexToo() throws {
        let cache = SchoolMailTestDoubles.temporaryCache()
        defer { cache.clearAll() }
        #expect(MailSearchIndexTests.fill(cache, [1: MailSearchIndexTests.text(subject: "期中考教室", body: nil)]))
        #expect(cache.bytes(in: .messages) > 0)

        cache.clear(.messages)

        #expect(cache.bytes(in: .messages) == 0)
        #expect(cache.searchIndex.search(folder: "INBOX", query: "期中考")?.uids.isEmpty != false)
    }

    @MainActor
    @Test func theMoodleFilesRowLeavesPicturesAndCourseRecordsToTheirOwnRow() async throws {
        let place = try MoodlePlace()
        defer { place.remove() }
        let downloads = MoodleFileDownloads(root: place.files.moodleFilesDir)
        let data = MoodleUserData(files: place.files)

        #expect(await downloads.measure() == 3_000)
        #expect(await data.measure() == 300)

        _ = await downloads.clear()
        #expect(!FileManager.default.fileExists(atPath: place.download.path))
        #expect(!FileManager.default.fileExists(atPath: place.stray.path))
        #expect(FileManager.default.fileExists(atPath: place.picture.path))
        #expect(FileManager.default.fileExists(atPath: place.record.path))

        await data.clear()
        #expect(!FileManager.default.fileExists(atPath: place.picture.path))
        #expect(!FileManager.default.fileExists(atPath: place.record.path))
        #expect(await data.measure() == 0)
    }

    @MainActor
    @Test func theMoodleDataRowLeavesDownloadedFiles() async throws {
        let place = try MoodlePlace()
        defer { place.remove() }

        await MoodleUserData(files: place.files).clear()

        #expect(FileManager.default.fileExists(atPath: place.download.path))
        #expect(await MoodleFileDownloads(root: place.files.moodleFilesDir).measure() == 3_000)
    }

    @MainActor
    @Test func theMacsMoodleCacheRowStillCountsAndClearsMemberPictures() async throws {
        let place = try MoodlePlace()
        defer { place.remove() }
        let downloads = MoodleFileDownloads(root: place.files.moodleFilesDir)
        let data = MoodleUserData(files: place.files)

        #expect(await MoodleFilesCacheSection.measure(downloads, data) == 3_300)
        #expect(await MoodleFilesCacheSection.clear(downloads, data) == 0)
        #expect(!FileManager.default.fileExists(atPath: place.picture.path))
    }

    @MainActor
    private struct MoodlePlace {
        let root = FileManager.default.temporaryDirectory.appending(path: "MoodlePlace-\(UUID().uuidString)", directoryHint: .isDirectory)
        let files: MoodleFiles
        let download: URL
        let stray: URL
        let picture: URL
        let record: URL

        init() throws {
            files = MoodleFiles(folders: CacheFolders(root: root))
            let account = files.moodleFilesDir.appending(path: "B11399001", directoryHint: .isDirectory)
            download = account.appending(path: "20119/m9301/0a1b/week3.pptx")
            stray = files.moodleFilesDir.appending(path: "slides.pdf")
            picture = account.appending(path: "\(MoodleFileDownloads.picturesFolder)/B11399002")
            record = files.moodleDir.appending(path: "B11399001/courses/20119/materials.json")
            for (file, size) in [(download, 2_000), (stray, 1_000), (picture, 100), (record, 200)] {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 1, count: size).write(to: file)
            }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func websiteDataIsTheSizeOfItsFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(BrowserData.storeBytes(in: folder, inUse: false) == 0)
        #expect(BrowserData.storeBytes(in: folder, inUse: true) == nil)

        let cookies = folder.appendingPathComponent("Cookies", isDirectory: true)
        try FileManager.default.createDirectory(at: cookies, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1_234).write(to: cookies.appendingPathComponent("Cookies.binarycookies"))
        #expect(BrowserData.storeBytes(in: folder, inUse: true) == 1_234)
    }
}
#endif
