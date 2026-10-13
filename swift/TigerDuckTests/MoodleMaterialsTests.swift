import Foundation
import os
import Testing
@testable import TigerDuck

/// A course's materials through `MoodleCourseStore` over a stand-in `MoodleCourseAPI`, with the
/// cache and the downloaded files in a folder of their own: the section row's count, the gating,
/// the cache, the downloads and what a screen opens.
@MainActor
struct MoodleMaterialsTests {
    private nonisolated static let courseId = 20119
    private nonisolated static let functions: Set<String> = [
        MoodleCourseContentsService.contentsFunction, "mod_resource_view_resource", "mod_url_view_url",
    ]

    private nonisolated static func file(_ name: String, path: String = "/", modified: TimeInterval = 0) -> MoodleFile {
        MoodleFile(
            name: name, size: 1024, url: "https://moodle2.ntust.edu.tw/webservice/pluginfile.php/31/mod_resource/content/1/\(name)",
            mimeType: name.hasSuffix(".pdf") ? "application/pdf" : nil,
            modified: Date(timeIntervalSince1970: 1_788_000_000 + modified), path: path
        )
    }

    private nonisolated static let syllabus = MoodleMaterial(
        id: 9101, instance: 301, module: "resource", name: "Syllabus", content: .file(file("syllabus.pdf"))
    )
    private nonisolated static let reading = MoodleMaterial(
        id: 9201, instance: 401, module: "url", name: "HTTP reading",
        content: .link(URL(string: "https://developer.mozilla.org/en-US/docs/Web/HTTP")!)
    )
    private nonisolated static let lab = MoodleMaterial(
        id: 9301, instance: 501, module: "folder", name: "Lab 1",
        content: .folder([file("spec.pdf"), file("starter.zip", path: "/code/"), file("format.docx")])
    )
    private nonisolated static let materials = MoodleCourseMaterials(sections: [
        MoodleMaterialSection(id: 100, name: "General", materials: [syllabus]),
        MoodleMaterialSection(id: 101, name: "Week 1", materials: [reading, lab]),
    ])

    /// The calls the store made, and what the stand-in site answers.
    private final class Site: @unchecked Sendable {
        private let lock = NSLock()
        private var _functions = MoodleMaterialsTests.functions
        private var _materials = MoodleMaterialsTests.materials
        private var _materialsCalls: [Int] = []
        private var _viewed: [Int] = []
        private var _downloads: [String] = []
        private var _failure: (any Error)?

        func set(functions: Set<String>? = nil, materials: MoodleCourseMaterials? = nil, failure: (any Error)? = nil) {
            lock.withLock {
                if let functions { _functions = functions }
                if let materials { _materials = materials }
                _failure = failure
            }
        }

        var materialsCalls: [Int] { lock.withLock { _materialsCalls } }
        var viewed: [Int] { lock.withLock { _viewed } }
        var downloads: [String] { lock.withLock { _downloads } }

        /// `beforeDownload` runs once a download starts, with its progress callback; it throws to
        /// fail the download.
        func api(
            beforeMaterials: @escaping @Sendable () async -> Void = {},
            beforeDownload: @escaping @Sendable (_ file: MoodleFile, _ progress: @escaping @Sendable (Double) -> Void) async throws -> Void = { _, _ in }
        ) -> MoodleCourseAPI {
            MoodleCourseAPI(
                functions: { self.lock.withLock { self._functions } },
                forums: { _ in [] },
                discussions: { _, _ in [] },
                markViewed: { _ in },
                materials: { courseId in
                    await beforeMaterials()
                    return try self.lock.withLock {
                        self._materialsCalls.append(courseId)
                        if let failure = self._failure { throw failure }
                        return self._materials
                    }
                },
                markMaterialViewed: { material in self.lock.withLock { self._viewed.append(material.id) } },
                download: { file, progress in
                    self.lock.withLock { self._downloads.append(file.name) }
                    try await beforeDownload(file, progress)
                    try Task.checkCancellation()
                    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try Data("contents of \(file.name)".utf8).write(to: temporary)
                    return temporary
                }
            )
        }
    }

    /// A cache and a files folder of their own, removed when the test ends.
    @MainActor
    private final class Folder {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoodleMaterialsTests-\(UUID().uuidString)", isDirectory: true)
        lazy var cache = DataCache(
            cacheDir: root.appendingPathComponent("cache", isDirectory: true),
            persistentDir: root.appendingPathComponent("persistent", isDirectory: true)
        )
        lazy var downloads = MoodleFileDownloads(root: cache.moodleFilesDir)

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private static func store(
        _ folder: Folder,
        site: Site,
        account: String = "B11399001",
        signedIn: OSAllocatedUnfairLock<Bool> = OSAllocatedUnfairLock(initialState: true),
        beforeMaterials: @escaping @Sendable () async -> Void = {},
        beforeDownload: @escaping @Sendable (_ file: MoodleFile, _ progress: @escaping @Sendable (Double) -> Void) async throws -> Void = { _, _ in }
    ) -> MoodleCourseStore {
        MoodleCourseStore(
            courseId: courseId,
            termCourseIds: [courseId],
            context: MoodleCacheContext(account: account, cache: folder.cache, isCurrent: { signedIn.withLock { $0 } }),
            api: site.api(beforeMaterials: beforeMaterials, beforeDownload: beforeDownload),
            downloads: folder.downloads
        )
    }

    private static let syllabusRef = MoodleFileRef(file: file("syllabus.pdf"), owner: .module(9101))

    // MARK: - Section row

    @Test("the materials row counts files and links, each file of a folder on its own")
    func rowCount() async {
        let folder = Folder()
        let store = Self.store(folder, site: Site())

        await store.refreshMaterials()

        #expect(store.sectionRows == [MoodleSectionRow(kind: .materials, count: 5, hasUnread: false)])
        #expect(MoodleCourseSection.route(for: .materials) == .materials)
    }

    @Test("a site that does not allow the call hides the row without asking for the materials")
    func gatedByFunctions() async {
        let folder = Folder()
        let site = Site()
        site.set(functions: [MoodleForumService.forumsFunction])
        let store = Self.store(folder, site: site)

        await store.refreshMaterials()

        #expect(site.materialsCalls.isEmpty)
        #expect(store.sectionRows.isEmpty)
        #expect(store.materials.status == .ok)
    }

    @Test("a refresh that empties the materials takes the row with it and leaves the list empty")
    func emptiedMaterialsHideTheRow() async {
        let folder = Folder()
        let site = Site()
        let store = Self.store(folder, site: site)
        await store.refreshMaterials()
        #expect(!store.sectionRows.isEmpty)

        site.set(materials: MoodleCourseMaterials(sections: []))
        await store.refreshMaterials()

        #expect(store.materials.value?.sections == [])
        #expect(store.sectionRows.isEmpty)
    }

    @Test("a failed first fetch leaves nothing to show but the error, and a failed later one keeps the list")
    func failures() async {
        let folder = Folder()
        let site = Site()
        site.set(failure: MoodleWebserviceError.transientNetwork(underlying: "offline"))
        let store = Self.store(folder, site: site)

        await store.refreshMaterials()
        #expect(store.materials.value == nil)
        #expect(store.materials.failure != nil)
        #expect(store.sectionStatus == .failed)

        site.set()
        await store.refreshMaterials()
        site.set(failure: MoodleWebserviceError.siteMaintenance)
        await store.refreshMaterials()
        #expect(store.materials.value == Self.materials)
        #expect(store.materials.status == .failed)
        #expect(store.sectionRows.map(\.kind) == [.materials])
    }

    @Test("the section dot shows a failed feed first, else OK once one feed reads OK, and spins while either fetches")
    func sectionStatus() async throws {
        let folder = Folder()
        let site = Site()
        let answer = ManualSleeper()
        let store = Self.store(folder, site: site, beforeMaterials: { await answer.sleep(for: .zero) })
        #expect(store.sectionStatus == .unknown)

        let first = Task { await store.refreshMaterials() }
        try await answer.waitUntilArmed()
        #expect(store.isSectionRefreshing)
        await answer.fire()
        await first.value
        #expect(!store.isSectionRefreshing)
        #expect(store.forums.status == .unknown)
        #expect(store.sectionStatus == .ok)

        await store.refreshForums()
        site.set(failure: MoodleWebserviceError.siteMaintenance)
        let failing = Task { await store.refreshMaterials() }
        try await answer.waitUntilArmed(atLeast: 2)
        await answer.fire()
        await failing.value
        #expect(store.forums.status == .ok)
        #expect(store.sectionStatus == .failed)
    }

    // MARK: - Cache

    @Test("materials are cached per account, shown before anything is asked, and fresh for five minutes")
    func cache() async {
        let folder = Folder()
        await Self.store(folder, site: Site()).refreshMaterials()

        let again = Self.store(folder, site: Site())
        #expect(again.materials.value == Self.materials)
        #expect(again.sectionRows.map(\.count) == [5])
        #expect(again.materialsFetchedAt != nil)
        #expect(again.materials.ttl == 5 * 60)
        #expect(Self.store(folder, site: Site(), account: "B11399002").materials.value == nil)
    }

    @Test("an answer that lands after a sign-out is neither shown nor kept")
    func signOutWhileFetching() async {
        let folder = Folder()
        let signedIn = OSAllocatedUnfairLock(initialState: true)
        let store = Self.store(folder, site: Site(), signedIn: signedIn)
        signedIn.withLock { $0 = false }

        await store.refreshMaterials()

        #expect(store.materials.value == nil)
        #expect(folder.cache.loadMoodleData(MoodleCourseMaterials.self, name: "courses/20119/materials", account: "B11399001") == nil)
    }

    @Test("signing out deletes the cached materials and every downloaded file")
    func signOutClearsEverything() async throws {
        let folder = Folder()
        let store = Self.store(folder, site: Site())
        await store.refreshMaterials()
        let copy = try #require(await store.download(Self.syllabusRef.file, in: Self.syllabusRef.owner))
        #expect(FileManager.default.fileExists(atPath: copy.path))

        folder.cache.clearUserScopedData()

        #expect(!FileManager.default.fileExists(atPath: folder.cache.moodleFilesDir.path))
        #expect(folder.cache.loadMoodleData(MoodleCourseMaterials.self, name: "courses/20119/materials", account: "B11399001") == nil)
        #expect(store.downloadState(of: Self.syllabusRef.file, in: Self.syllabusRef.owner) == .notDownloaded)
    }

    // MARK: - Views on Moodle

    @Test("opening a file or link logs its module's view once, only when the site allows that call")
    func viewEvents() async {
        let folder = Folder()
        let site = Site()
        let store = Self.store(folder, site: site)

        await store.open(Self.syllabus).value
        await store.open(Self.reading).value
        await store.open(Self.lab).value

        #expect(site.viewed == [9101, 9201])
    }

    // MARK: - Downloads

    @Test("a file downloads once however often it is asked for, with its progress on the way")
    func downloadOnce() async throws {
        let folder = Folder()
        let site = Site()
        let gate = ManualSleeper()
        let store = Self.store(folder, site: site, beforeDownload: { _, progress in
            progress(0.456)
            await gate.sleep(for: .zero)
        })
        let file = Self.syllabusRef.file

        let first = Task { await store.download(file, in: .module(9101)) }
        try await gate.waitUntilArmed()
        let second = Task { await store.download(file, in: .module(9101)) }
        try await waitUntil { store.downloadState(of: file, in: .module(9101)) == .downloading(progress: 0.45) }
        await gate.fire()
        let copies = [await first.value, await second.value]

        #expect(site.downloads == ["syllabus.pdf"])
        let copy = try #require(copies[0])
        #expect(copies[1] == copy)
        #expect(copy.lastPathComponent == "syllabus.pdf")
        #expect(try String(contentsOf: copy, encoding: .utf8) == "contents of syllabus.pdf")
        #expect(store.downloadState(of: file, in: .module(9101)) == .downloaded(copy))
        #expect(await store.download(file, in: .module(9101)) == copy)
        #expect(site.downloads.count == 1)
    }

    @Test("a cancelled download leaves no file and shows as not downloaded")
    func cancelDownload() async throws {
        let folder = Folder()
        let gate = ManualSleeper()
        let store = Self.store(folder, site: Site(), beforeDownload: { _, _ in await gate.sleep(for: .zero) })
        let file = Self.syllabusRef.file

        let download = Task { await store.download(file, in: .module(9101)) }
        try await gate.waitUntilArmed()
        store.cancelDownload(of: file, in: .module(9101))

        #expect(store.downloadState(of: file, in: .module(9101)) == .notDownloaded)
        #expect(await download.value == nil)
        #expect(store.downloadState(of: file, in: .module(9101)) == .notDownloaded)
        #expect(!FileManager.default.fileExists(atPath: store.location(of: file, in: .module(9101)).path))
    }

    @Test("a failed download shows its error and downloads on the next try")
    func failedDownload() async throws {
        let folder = Folder()
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let store = Self.store(folder, site: Site(), beforeDownload: { _, _ in
            if attempts.withLock({ count in
                count += 1
                return count == 1
            }) {
                throw MoodleWebserviceError.transientNetwork(underlying: "offline")
            }
        })
        let file = Self.syllabusRef.file

        #expect(await store.download(file, in: .module(9101)) == nil)
        #expect(store.downloadState(of: file, in: .module(9101)) == .failed(message: String(localized: "error_network_unavailable")))

        let copy = try #require(await store.download(file, in: .module(9101)))
        #expect(store.downloadState(of: file, in: .module(9101)) == .downloaded(copy))
    }

    @Test("a download that ends after a sign-out writes nothing and shows no failure")
    func downloadAfterSignOut() async throws {
        let folder = Folder()
        let signedIn = OSAllocatedUnfairLock(initialState: true)
        let gate = ManualSleeper()
        let store = Self.store(folder, site: Site(), signedIn: signedIn, beforeDownload: { _, _ in await gate.sleep(for: .zero) })
        let file = Self.syllabusRef.file

        let download = Task { await store.download(file, in: .module(9101)) }
        try await gate.waitUntilArmed()
        signedIn.withLock { $0 = false }
        await gate.fire()

        #expect(await download.value == nil)
        #expect(store.downloadState(of: file, in: .module(9101)) == .notDownloaded)
        #expect(!FileManager.default.fileExists(atPath: store.location(of: file, in: .module(9101)).path))
    }

    @Test("a copy of an older version counts as not downloaded and goes when the materials refresh")
    func newerVersion() async throws {
        let folder = Folder()
        let site = Site()
        let store = Self.store(folder, site: site)
        await store.refreshMaterials()
        let copy = try #require(await store.download(Self.syllabusRef.file, in: .module(9101)))

        let newer = Self.file("syllabus.pdf", modified: 60)
        #expect(store.location(of: newer, in: .module(9101)) == copy)
        #expect(store.downloadState(of: newer, in: .module(9101)) == .notDownloaded)

        site.set(materials: MoodleCourseMaterials(sections: [
            MoodleMaterialSection(id: 100, name: "General", materials: [
                MoodleMaterial(id: 9101, instance: 301, module: "resource", name: "Syllabus", content: .file(newer)),
            ]),
        ]))
        await store.refreshMaterials()
        #expect(!FileManager.default.fileExists(atPath: copy.path))
    }

    @Test("a download of a version Moodle no longer lists stops, and so does one a newer version asks for")
    func outdatedDownloadStops() async throws {
        let folder = Folder()
        let site = Site()
        let gate = ManualSleeper()
        let store = Self.store(folder, site: site, beforeDownload: { _, _ in await gate.sleep(for: .zero) })
        await store.refreshMaterials()
        let old = Self.syllabusRef.file
        let newer = Self.file("syllabus.pdf", modified: 60)

        let first = Task { await store.download(old, in: .module(9101)) }
        try await gate.waitUntilArmed()
        site.set(materials: MoodleCourseMaterials(sections: [
            MoodleMaterialSection(id: 100, name: "General", materials: [
                MoodleMaterial(id: 9101, instance: 301, module: "resource", name: "Syllabus", content: .file(newer)),
            ]),
        ]))
        await store.refreshMaterials()
        #expect(await first.value == nil)
        #expect(!FileManager.default.fileExists(atPath: store.location(of: old, in: .module(9101)).path))

        let stale = Task { await store.download(old, in: .module(9101)) }
        try await gate.waitUntilArmed(atLeast: 2)
        let fresh = Task { await store.download(newer, in: .module(9101)) }
        try await gate.waitUntilArmed(atLeast: 3)
        await gate.fire()
        #expect(await stale.value == nil)
        let copy = try #require(await fresh.value)
        #expect(store.downloadState(of: newer, in: .module(9101)) == .downloaded(copy))
        #expect(store.downloadState(of: old, in: .module(9101)) == .notDownloaded)
    }

    @Test("files of one name in different folders, posts or accounts are kept apart")
    func locations() {
        let folder = Folder()
        let downloads = folder.downloads
        let spec = Self.file("spec.pdf")
        let other = Self.file("spec.pdf", path: "/week2/")

        let first = downloads.location(of: spec, owner: .module(9301), courseId: 20119, account: "B11399001")
        #expect(first.lastPathComponent == "spec.pdf")
        #expect(first.path.hasPrefix(folder.cache.moodleFilesDir.appendingPathComponent("B11399001/20119/m9301").path))
        #expect(downloads.location(of: other, owner: .module(9301), courseId: 20119, account: "B11399001") != first)
        #expect(downloads.location(of: spec, owner: .post(7001), courseId: 20119, account: "B11399001") != first)
        #expect(downloads.location(of: spec, owner: .module(9301), courseId: 20119, account: "B11399002") != first)
        #expect(downloads.location(of: Self.file(".."), owner: .module(1), courseId: 1, account: "../x").lastPathComponent == "file")
        #expect(!downloads.location(of: Self.file("a"), owner: .module(1), courseId: 1, account: "../x").path.contains(".."))
    }

    @Test("the settings measure the downloaded files, and clearing deletes them all and stops the downloads on their way")
    func clear() async throws {
        let folder = Folder()
        let gate = ManualSleeper()
        let store = Self.store(folder, site: Site(), beforeDownload: { file, _ in
            if file.name == "spec.pdf" { await gate.sleep(for: .zero) }
        })
        #expect(await folder.downloads.measure() == 0)
        _ = try #require(await store.download(Self.syllabusRef.file, in: .module(9101)))
        #expect(await folder.downloads.measure() == "contents of syllabus.pdf".utf8.count)
        let running = Task { await store.download(Self.file("spec.pdf"), in: .module(9301)) }
        try await gate.waitUntilArmed()

        let left = await folder.downloads.clear()

        #expect(left == 0)
        #expect(await running.value == nil)
        #expect(store.downloadState(of: Self.syllabusRef.file, in: .module(9101)) == .notDownloaded)
        #expect(await folder.downloads.measure() == 0)
    }

    // MARK: - Opening on screen

    @Test("a file that finishes downloading opens only if it was the last tapped and the screen still shows")
    func autoOpen() async throws {
        let folder = Folder()
        let first = ManualSleeper()
        let second = ManualSleeper()
        let store = Self.store(folder, site: Site(), beforeDownload: { file, _ in
            await (file.name == "spec.pdf" ? first : second).sleep(for: .zero)
        })
        let spec = MoodleFileRef(file: Self.file("spec.pdf"), owner: .module(9301))
        let format = MoodleFileRef(file: Self.file("format.docx"), owner: .module(9301))
        let opener = MoodleFileOpener()
        opener.isOnScreen = true

        opener.tap(spec, among: [spec, format], store: store)
        try await first.waitUntilArmed()
        opener.tap(format, among: [spec, format], store: store)
        try await second.waitUntilArmed()
        await first.fire()
        try await waitUntil { store.downloadState(of: spec.file, in: spec.owner) != .downloading(progress: 0) }
        #expect(opener.preview == nil)

        await second.fire()
        let copy = store.location(of: format.file, in: format.owner)
        try await waitUntil { opener.preview == copy }
        #expect(opener.previewItems == [store.location(of: spec.file, in: spec.owner), copy])
    }

    @Test("a file that finishes downloading after the screen closes does not open")
    func noOpenOffScreen() async throws {
        let folder = Folder()
        let gate = ManualSleeper()
        let store = Self.store(folder, site: Site(), beforeDownload: { _, _ in await gate.sleep(for: .zero) })
        let opener = MoodleFileOpener()
        opener.isOnScreen = true

        opener.tap(Self.syllabusRef, among: [Self.syllabusRef], store: store)
        try await gate.waitUntilArmed()
        opener.isOnScreen = false
        await gate.fire()
        try await waitUntil { store.downloadState(of: Self.syllabusRef.file, in: Self.syllabusRef.owner) != .downloading(progress: 0) }

        #expect(opener.preview == nil)
        #expect(store.downloadState(of: Self.syllabusRef.file, in: Self.syllabusRef.owner) != .notDownloaded)
    }

    @Test("a Share chosen while a tapped file downloads shares it without also opening a preview")
    func shareReplacesThePreview() async throws {
        let folder = Folder()
        let gate = ManualSleeper()
        let store = Self.store(folder, site: Site(), beforeDownload: { _, _ in await gate.sleep(for: .zero) })
        let opener = MoodleFileOpener()
        opener.isOnScreen = true
        let copy = store.location(of: Self.syllabusRef.file, in: Self.syllabusRef.owner)

        opener.tap(Self.syllabusRef, among: [Self.syllabusRef], store: store)
        try await gate.waitUntilArmed()
        opener.share(Self.syllabusRef, store: store)
        await gate.fire()

        // The tap started the download, so its check has run once the download's state settles.
        try await waitUntil {
            opener.shared != nil && store.downloadState(of: Self.syllabusRef.file, in: Self.syllabusRef.owner) == .downloaded(copy)
        }
        #expect(opener.shared?.url == copy)
        #expect(opener.preview == nil)
    }

    @Test("a link opened while a tapped file downloads keeps the file from opening over its page")
    func linkReplacesThePreview() async throws {
        let folder = Folder()
        let gate = ManualSleeper()
        let store = Self.store(folder, site: Site(), beforeDownload: { _, _ in await gate.sleep(for: .zero) })
        let opener = MoodleFileOpener()
        opener.isOnScreen = true
        let link = URL(string: "https://developer.mozilla.org/en-US/docs/Web/HTTP")!
        var opened: [URL] = []

        opener.tap(Self.syllabusRef, among: [Self.syllabusRef], store: store)
        try await gate.waitUntilArmed()
        opener.open(link: link) { opened.append($0) }
        await gate.fire()

        let copy = store.location(of: Self.syllabusRef.file, in: Self.syllabusRef.owner)
        try await waitUntil { store.downloadState(of: Self.syllabusRef.file, in: Self.syllabusRef.owner) == .downloaded(copy) }
        #expect(opened == [link])
        #expect(opener.preview == nil)
    }

    @Test("a tap on a downloading file stops it, and HTML or SVG opens in the share sheet, never Quick Look")
    func tapStopsAndSharesHTML() async throws {
        let folder = Folder()
        let gate = ManualSleeper()
        let store = Self.store(folder, site: Site(), beforeDownload: { file, _ in
            if file.name == "slow.pdf" { await gate.sleep(for: .zero) }
        })
        let opener = MoodleFileOpener()
        opener.isOnScreen = true
        let slow = MoodleFileRef(file: Self.file("slow.pdf"), owner: .module(1))
        opener.tap(slow, among: [slow], store: store)
        try await gate.waitUntilArmed()
        opener.tap(slow, among: [slow], store: store)
        #expect(store.downloadState(of: slow.file, in: slow.owner) == .notDownloaded)

        let page = MoodleFileRef(file: Self.file("notes.html"), owner: .module(2))
        let drawing = MoodleFile(name: "graph", size: 1, url: "https://moodle2.ntust.edu.tw/x", mimeType: "image/svg+xml", modified: nil)
        #expect(page.file.opensInShareSheet)
        #expect(drawing.opensInShareSheet)
        #expect(!Self.syllabusRef.file.opensInShareSheet)
        opener.tap(page, among: [page], store: store)
        try await waitUntil { opener.shared != nil }
        #expect(opener.shared?.url == store.location(of: page.file, in: page.owner))
        #expect(opener.preview == nil)
    }
}
