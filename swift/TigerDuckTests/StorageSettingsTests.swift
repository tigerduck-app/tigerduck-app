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

    @Test func theTotalAddsWhatWasMeasuredAndSkipsWhatWasNot() async {
        let sizes = await Stores([.moodleFiles: 3_000, .mail: 1_000, .websiteData: nil]).cleaner.measure()
        #expect(sizes.bytes == [.moodleFiles: 3_000, .mail: 1_000])
        #expect(sizes.total == 4_000)
    }

    @Test func theBarHasAPartForEachKindAboveZeroInPageOrder() {
        let sizes = StorageSizes(bytes: [.websiteData: 1_000, .moodleFiles: 3_000, .mail: 0])
        #expect(sizes.segments == [
            StorageSizes.Segment(kind: .moodleFiles, share: 0.75),
            StorageSizes.Segment(kind: .websiteData, share: 0.25),
        ])
    }

    @Test func anEmptyOrUnmeasuredPageHasNoBar() {
        #expect(StorageSizes().segments.isEmpty)
        #expect(StorageSizes(bytes: [.moodleFiles: 0, .mail: 0]).segments.isEmpty)
    }

    @Test(arguments: StorageKind.allCases)
    func aDeleteClearsOnlyItsOwnKindThenMeasuresAgain(kind: StorageKind) async {
        let stores = Stores([.moodleFiles: 3_000, .mail: 2_000, .websiteData: 1_000])
        let sizes = await stores.cleaner.delete(kind)
        #expect(stores.clears == [kind])
        #expect(sizes.bytes[kind] == 0)
        #expect(sizes.total == 6_000 - [StorageKind.moodleFiles: 3_000, .mail: 2_000, .websiteData: 1_000][kind]!)
    }

    @Test func onlyMailAndWebsiteDataAskBeforeDeleting() {
        #expect(!StorageKind.moodleFiles.confirmsDelete)
        #expect(StorageKind.mail.confirmsDelete)
        #expect(StorageKind.websiteData.confirmsDelete)
    }

    @Test func theMailRowMeasuresEverythingTheCacheKeepsAndClearingEmptiesIt() async throws {
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
        let store = StorageCleaner.Store.mail(cache)

        let measured = try #require(await store.measure())
        #expect(measured > cache.bodyBytes())
        #expect(measured > 700)

        await store.clear()
        #expect(await store.measure() == 0)
        #expect(cache.loadPage(folder: "INBOX") == nil)
        #expect(!FileManager.default.fileExists(atPath: attachment.path))
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
