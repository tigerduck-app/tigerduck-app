#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

/// The course detail's Moodle section laid out in a window and measured, as
/// `MoodleDiscussionCardTests` measures its card: with nothing to show it adds no view and no
/// spacing, a summary alone brings it, and the closed summary stops at four lines.
@MainActor
struct MoodleCourseSectionTests {
    private static let policy = VisualStylePolicy(preset: .default)
    private static let longText = String(repeating: "本課程介紹電腦網路的分層架構與常見協定，每兩週一次實作 Lab。", count: 6)

    private static func summary(_ text: String) -> MoodleCourseSummary {
        MoodleCourseSummary(html: "<p>\(text)</p>", text: text, names: ["Computer Networks"])
    }

    private static func store(summary: MoodleCourseSummary, forums: [MoodleForum] = []) async -> MoodleCourseStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoodleCourseSectionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MoodleCourseStore(
            courseId: 20119,
            termCourseIds: [20119],
            courseCodes: ["1141CS3105301", "CS3105301"],
            context: MoodleCacheContext(
                account: "B11399001",
                cache: DataCache(
                    cacheDir: root.appendingPathComponent("cache", isDirectory: true),
                    persistentDir: root.appendingPathComponent("persistent", isDirectory: true)
                ),
                isCurrent: { true }
            ),
            api: MoodleCourseAPI(
                functions: {
                    [MoodleForumService.forumsFunction, MoodleForumService.discussionsFunction,
                     MoodleCourseSummaryService.coursesFunction]
                },
                forums: { _ in forums },
                discussions: { _, _ in [] },
                markViewed: { _, _ in },
                summary: { _ in summary }
            )
        )
        await store.refreshForums()
        await store.refreshSummary()
        return store
    }

    private func height(_ view: some View, width: CGFloat = 390) -> CGFloat {
        let host = UIHostingController(rootView: view.frame(width: width))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 900))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    /// `section` between two bars in a stack with no spacing, as the course detail lays it out.
    private func stacked(_ section: MoodleCourseSection?) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 10)
            if let section { section }
            Color.clear.frame(height: 10)
        }
    }

    @Test("with no row and no summary worth showing, the section adds no view and no spacing")
    func nothingToShow() async {
        let empty = await Self.store(summary: .empty)
        let repeating = await Self.store(summary: Self.summary("1141 CS3105301"))
        let without = height(stacked(nil))

        #expect(height(stacked(MoodleCourseSection(store: empty, policy: Self.policy))) == without)
        #expect(height(stacked(MoodleCourseSection(store: repeating, policy: Self.policy))) == without)
    }

    @Test("a summary alone brings the section, though it has no row")
    func summaryAlone() async {
        let store = await Self.store(summary: Self.summary("本課程介紹電腦網路的分層架構。"))
        #expect(store.sectionRows.isEmpty)

        #expect(height(stacked(MoodleCourseSection(store: store, policy: Self.policy))) > height(stacked(nil)))
    }

    @Test("the closed summary stops at four lines however long the summary, ending in an ellipsis")
    func previewStopsAtFourLines() {
        let oneLine = height(Text(verbatim: "期").font(.body))
        let fourLines = height(Text(verbatim: "期\n期\n期\n期").font(.body))
        let short = height(MoodleCourseSummaryView(summary: Self.summary("本課程介紹電腦網路。")))
        let long = height(MoodleCourseSummaryView(summary: Self.summary(Self.longText)))
        let longer = height(MoodleCourseSummaryView(summary: Self.summary(Self.longText + Self.longText)))

        #expect(abs((long - short) - (fourLines - oneLine)) < 1, "grew \(long - short)pt, not three lines")
        #expect(abs(longer - long) < 0.5, "grew from \(long)pt to \(longer)pt")
    }

    @Test("an announcements screen whose refreshed news forum disappears stops showing the initial spinner")
    func announcementsWithoutNewsForum() async throws {
        let store = await Self.store(summary: .empty)
        #expect(store.announcementPages == nil)
        #expect(store.forumsFetchedAt != nil)
        #expect(hasSpinner(MoodleFirstLoadView(failure: nil, retry: {})))
        #expect(!hasSpinner(MoodleAnnouncementsView(store: store) { _ in }))
    }

    private func hasSpinner(_ view: some View) -> Bool {
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        func spinners(in view: UIView) -> [UIActivityIndicatorView] {
            view.subviews.flatMap { [$0 as? UIActivityIndicatorView].compactMap { $0 } + spinners(in: $0) }
        }
        return !spinners(in: host.view).isEmpty
    }
}
#endif
