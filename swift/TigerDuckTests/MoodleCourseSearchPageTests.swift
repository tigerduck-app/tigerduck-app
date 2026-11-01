#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct MoodleCourseSearchPageTests {
    private typealias Fixtures = MoodleCourseSearchTests
    private static let courseId = 20119
    private static let longTitle =
        "Midterm examination room assignments and the seating chart for the evening section of Computer Networks"
    private static let longQuery = "midterm examination room assignments and the seating chart"
    private static let longMiss = "quantum chromodynamics lecture recordings from the previous academic year"
    private static let longItem =
        "Lecture notes on distributed consensus, leader election and the failure detectors the final project builds on"

    private static let announcements = [
        Fixtures.announcement(1, title: longTitle, html: "<p>Rooms are listed below.</p>", author: "Tiger Teacher"),
        Fixtures.announcement(2, title: "Week 5 has no class", html: "<p>Enjoy the holiday</p>"),
        Fixtures.announcement(3, title: "Lab 3 hand-in moved to Friday", html: "<p>See the <b>lab</b> page</p>"),
    ]

    private static let materials = MoodleCourseMaterials(sections: Fixtures.materials.sections + [
        MoodleMaterialSection(id: 5, name: "Week 4 distributed systems, from clocks and snapshots to consensus and replication", materials: [
            Fixtures.material(51, longItem, .file(Fixtures.file("notes4.pdf"))),
        ], number: 4),
    ])

    private final class PageRequests: @unchecked Sendable {
        private let lock = NSLock()
        private var pages: [Int] = []

        func record(_ page: Int) { lock.withLock { pages.append(page) } }
        var requested: [Int] { lock.withLock { pages } }
    }

    private final class Folder {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoodleCourseSearchPageTests-\(UUID().uuidString)", isDirectory: true)

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private static func store(
        _ folder: Folder, pages: [[MoodleDiscussion]] = [announcements], requests: PageRequests = PageRequests()
    ) -> MoodleCourseStore {
        let cache = TestCache(
            cacheDir: folder.root.appendingPathComponent("cache", isDirectory: true),
            persistentDir: folder.root.appendingPathComponent("persistent", isDirectory: true)
        )
        let news = MoodleForum(
            id: 501, courseId: courseId, type: "news", name: "Announcements", cmid: 8501,
            discussionCount: pages.joined().count, unreadPostCount: 0
        )
        return MoodleCourseStore(
            courseId: courseId,
            termCourseIds: [courseId],
            context: MoodleCacheContext(account: "B11399001", cache: cache.moodle, signIn: testSignIn),
            api: MoodleCourseAPI(
                functions: { MoodleCourseStore.forumFunctions.union([MoodleCourseContentsService.contentsFunction]) },
                forums: { _ in [news] },
                discussions: { _, page in
                    requests.record(page)
                    return page < pages.count ? pages[page] : []
                },
                markViewed: { _, _ in },
                materials: { _ in materials }
            ),
            downloads: MoodleFileDownloads(root: cache.moodleFilesDir)
        )
    }

    private static func announcementsPage(
        _ folder: Folder, pages: [[MoodleDiscussion]] = [announcements], requests: PageRequests = PageRequests()
    ) async throws -> some View {
        let store = store(folder, pages: pages, requests: requests)
        await store.refreshForums()
        await store.announcementPages?.refresh()
        #expect(store.announcementPages?.list?.discussions.count == pages.first?.count)
        return MoodleAnnouncementsView(store: store, policy: VisualStylePolicy(preset: .default)) { _ in }
    }

    private static func materialsPage(_ folder: Folder) async -> some View {
        let store = store(folder)
        await store.refreshMaterials()
        #expect(store.materials.value == materials)
        return MoodleMaterialsView(store: store, policy: VisualStylePolicy(preset: .default))
    }

    private static func show(_ page: some View, searching query: String) async throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 812)
        window.rootViewController = UIHostingController(rootView: NavigationStack { page })
        window.makeKeyAndVisible()
        try await waitUntil { window.descendants(ofType: UIScrollView.self).first.map { $0.contentSize.height > 0 } ?? false }
        let list = try #require(window.descendants(ofType: UIScrollView.self).first)
        list.contentOffset.y = -list.adjustedContentInset.top - 60
        try await waitUntil { !window.descendants(ofType: UITextField.self).isEmpty }
        let field = try #require(window.descendants(ofType: UITextField.self).first)
        field.becomeFirstResponder()
        try await waitUntil { field.isFirstResponder }
        field.insertText(query)
        list.contentOffset.y = -list.adjustedContentInset.top
        return window
    }

    /// A list keeps the cells of rows it no longer shows, hidden, for reuse.
    private static func labels(in window: UIWindow) -> [String] {
        guard let root = window.rootViewController?.view else { return [] }
        let shown: [UIView] = root.descendants(ofType: UICollectionView.self).first?.visibleCells ?? [root]
        return shown.flatMap { exposedAccessibilityLabels(in: $0) }
    }

    private static func shows(_ text: String, in window: UIWindow) -> Bool {
        labels(in: window).contains { $0.contains(text) }
    }

    private static func showsCard(titled title: String, in window: UIWindow) -> Bool {
        labels(in: window).contains { $0.hasPrefix("\(title),") }
    }

    private static func expectNoOverflow(in window: UIWindow, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let root = try #require(window.rootViewController?.view)
        let wide = exposedAccessibilityElements(in: root).filter {
            $0.accessibilityFrame.minX < -0.5 || $0.accessibilityFrame.maxX > window.bounds.width + 0.5
        }
        #expect(wide.isEmpty, "\(wide.map { $0.accessibilityLabel ?? "" })", sourceLocation: sourceLocation)
        for field in window.descendants(ofType: UITextField.self) {
            let frame = field.convert(field.bounds, to: window)
            #expect(frame.minX >= 0 && frame.maxX <= window.bounds.width, sourceLocation: sourceLocation)
        }
    }

    private static func save(_ window: UIWindow, as name: String) async throws {
        try await Task.sleep(for: .milliseconds(400))
        window.saveSnapshot(as: name)
    }

    private static func close(_ window: UIWindow) {
        window.endEditing(true)
        window.isHidden = true
    }

    @Test("a long query keeps only the announcement with the long subject it holds, inside the width")
    func announcementsQuery() async throws {
        try await withAccessibilityAutomation {
            let folder = Folder()
            let window = try await Self.show(try await Self.announcementsPage(folder), searching: Self.longQuery)
            defer { Self.close(window) }

            try await waitUntil { !Self.shows("Week 5 has no class", in: window) }

            #expect(Self.shows(Self.longTitle, in: window))
            #expect(!Self.shows("Lab 3 hand-in", in: window))
            try Self.expectNoOverflow(in: window)
            try await Self.save(window, as: "moodle-search-announcements-query")
        }
    }

    @Test("announcements that match nothing show the empty search state, inside the width")
    func announcementsNoMatch() async throws {
        try await withAccessibilityAutomation {
            let folder = Folder()
            let window = try await Self.show(try await Self.announcementsPage(folder), searching: Self.longMiss)
            defer { Self.close(window) }

            try await waitUntil { Self.shows(Self.longMiss, in: window) }

            #expect(!Self.shows(Self.longTitle, in: window))
            try Self.expectNoOverflow(in: window)
            try await Self.save(window, as: "moodle-search-announcements-empty")
        }
    }

    @Test("a long query keeps only the section of the long item it holds, inside the width")
    func materialsQuery() async throws {
        try await withAccessibilityAutomation {
            let folder = Folder()
            let window = try await Self.show(await Self.materialsPage(folder), searching: "lecture notes on distributed consensus")
            defer { Self.close(window) }

            try await waitUntil { !Self.shows("Syllabus", in: window) }

            #expect(Self.shows(Self.longItem, in: window))
            #expect(Self.shows("Week 4 distributed systems", in: window))
            #expect(!Self.shows("Lab files", in: window))
            try Self.expectNoOverflow(in: window)
            try await Self.save(window, as: "moodle-search-materials-query")
        }
    }

    @Test("materials that match nothing show the empty search state, inside the width")
    func materialsNoMatch() async throws {
        try await withAccessibilityAutomation {
            let folder = Folder()
            let window = try await Self.show(await Self.materialsPage(folder), searching: Self.longMiss)
            defer { Self.close(window) }

            try await waitUntil { Self.shows(Self.longMiss, in: window) }

            #expect(!Self.shows("Syllabus", in: window))
            try Self.expectNoOverflow(in: window)
            try await Self.save(window, as: "moodle-search-materials-empty")
        }
    }

    @Test("clearing a search that reached the last loaded announcement loads the next page")
    func clearingLoadsTheNextPage() async throws {
        try await withAccessibilityAutomation {
            let folder = Folder()
            let requests = PageRequests()
            let first = (1...MoodleForumService.discussionsPerPage).map {
                Fixtures.announcement($0, title: String(format: "Notice %02d", $0))
            }
            let page = try await Self.announcementsPage(folder, pages: [first], requests: requests)
            let window = try await Self.show(page, searching: "notice")
            defer { Self.close(window) }
            try await waitUntil { Self.shows(String(localized: "action_clear_text"), in: window) }
            let list = try #require(window.descendants(ofType: UICollectionView.self).first)

            try await waitUntil {
                let bottom = list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom
                list.setContentOffset(CGPoint(x: 0, y: max(bottom, -list.adjustedContentInset.top)), animated: false)
                return Self.showsCard(titled: "Notice 01", in: window)
            }
            try await Task.sleep(for: .milliseconds(300))
            #expect(requests.requested == [0])

            let field = try #require(window.descendants(ofType: UITextField.self).first)
            for _ in "notice" { field.deleteBackward() }

            try await waitUntil { requests.requested.contains(1) }
        }
    }
}
#endif
