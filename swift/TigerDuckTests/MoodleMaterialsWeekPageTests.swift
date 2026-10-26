#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
struct MoodleMaterialsWeekPageTests {
    private final class FetchGate: Sendable {
        private let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init() {
            (stream, continuation) = AsyncStream<Void>.makeStream()
        }

        func wait() async {
            for await _ in stream { return }
        }

        func open() {
            continuation.yield()
            continuation.finish()
        }
    }

    private nonisolated static func slides(week: Int) -> MoodleMaterial {
        let name = "week\(week).pdf"
        return MoodleMaterial(
            id: 9000 + week, instance: 300 + week, module: "resource", name: "Slides \(week)",
            content: .file(MoodleFile(
                name: name, size: 1024, url: "https://moodle-stub.invalid/webservice/pluginfile.php/31/mod_resource/content/1/\(name)",
                mimeType: "application/pdf", modified: Date(timeIntervalSince1970: 1_788_000_000), path: "/"
            ))
        )
    }

    /// With `datedAsWeek`, each name also carries its week's first day, counted so that today
    /// falls in that week rather than in the eighth the start date gives.
    private nonisolated static func sectionName(week: Int, datedAsWeek: Int?) -> String {
        guard week > 0 else { return "General" }
        let calendar = AppConstants.taipeiCalendar
        guard let datedAsWeek,
              let day = calendar.date(byAdding: .day, value: 7 * (week - datedAsWeek), to: calendar.startOfDay(for: AppClock.now()))
        else { return "Week \(week)" }
        let parts = calendar.dateComponents([.month, .day], from: day)
        return "Week \(week) \(parts.month ?? 0)/\(parts.day ?? 0)"
    }

    private nonisolated static func materials(datedAsWeek: Int?) -> MoodleCourseMaterials {
        MoodleCourseMaterials(sections: (0...16).map { week in
            MoodleMaterialSection(
                id: 100 + week, name: sectionName(week: week, datedAsWeek: datedAsWeek),
                materials: [slides(week: week)], number: week
            )
        })
    }

    private static func weeklyCourseInItsEighthWeek(
        in root: URL, datedAsWeek: Int? = nil, materialsGate: FetchGate? = nil, summaryGate: FetchGate? = nil
    ) -> MoodleCourseStore {
        let calendar = AppConstants.taipeiCalendar
        let start = calendar.date(byAdding: .day, value: -7 * 7, to: calendar.startOfDay(for: AppClock.now()))
        let course = MoodleCourseSummary(html: "", text: "", names: [], format: "weeks", startDate: start)
        let materials = materials(datedAsWeek: datedAsWeek)
        let cache = DataCache(
            cacheDir: root.appendingPathComponent("cache", isDirectory: true),
            persistentDir: root.appendingPathComponent("persistent", isDirectory: true)
        )
        return MoodleCourseStore(
            courseId: 20119,
            termCourseIds: [20119],
            context: MoodleCacheContext(account: "B11399001", cache: cache, isCurrent: { true }),
            api: MoodleCourseAPI(
                functions: { [MoodleCourseContentsService.contentsFunction, MoodleCourseSummaryService.coursesFunction] },
                forums: { _ in [] },
                discussions: { _, _ in [] },
                markViewed: { _, _ in },
                materials: { _ in
                    await materialsGate?.wait()
                    return materials
                },
                summary: { _ in
                    await summaryGate?.wait()
                    return course
                }
            ),
            downloads: MoodleFileDownloads(root: cache.moodleFilesDir)
        )
    }

    private static func present(_ store: MoodleCourseStore) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            MoodleMaterialsView(store: store, policy: VisualStylePolicy(preset: .default))
        })
        window.isHidden = false
        return window
    }

    private static func waitForTopHeader(_ label: String, in window: UIWindow) async throws {
        let page = try #require(window.rootViewController?.view)
        try await waitUntil(timeout: .seconds(15)) {
            accessibilityElement(labeled: label, in: page).map { $0.accessibilityFrame.minY < window.bounds.height / 3 } ?? false
        }
    }

    private static func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MoodleMaterialsWeekPageTests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("the materials open at this week's section, whose header alone is marked")
    func opensAtThisWeek() async throws {
        try await withAccessibilityAutomation {
            let root = Self.temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = Self.weeklyCourseInItsEighthWeek(in: root)
            await store.refreshMaterials()
            await store.refreshSummary()
            let window = try Self.present(store)
            defer { window.isHidden = true }

            try await Self.waitForTopHeader("Week 8", in: window)

            let page = try #require(window.rootViewController?.view)
            let header = try #require(accessibilityElement(labeled: "Week 8", in: page))
            #expect(header.accessibilityTraits.contains(.header))
            #expect(header.accessibilityTraits.contains(.selected))
            let next = try #require(accessibilityElement(labeled: "Week 9", in: page))
            #expect(next.accessibilityTraits.contains(.header))
            #expect(!next.accessibilityTraits.contains(.selected))
        }
    }

    @Test("materials that arrive after the page is shown still open at this week")
    func scrollsOnceTheMaterialsArrive() async throws {
        try await withAccessibilityAutomation {
            let root = Self.temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let gate = FetchGate()
            let store = Self.weeklyCourseInItsEighthWeek(in: root, materialsGate: gate)
            await store.refreshSummary()
            let loading = Task { await store.refreshMaterials() }
            let window = try Self.present(store)
            defer { window.isHidden = true }
            try await waitUntil { store.materials.isRefreshing }

            gate.open()
            await loading.value

            try await Self.waitForTopHeader("Week 8", in: window)
        }
    }

    @Test("a summary still loading holds the scroll, so its weekly format wins over the names' dates")
    func waitsForTheSummary() async throws {
        try await withAccessibilityAutomation {
            let root = Self.temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let gate = FetchGate()
            let store = Self.weeklyCourseInItsEighthWeek(in: root, datedAsWeek: 3, summaryGate: gate)
            await store.refreshMaterials()
            let loading = Task { await store.refreshSummary() }
            try await waitUntil { store.summary.isRefreshing }
            let window = try Self.present(store)
            defer { window.isHidden = true }
            let page = try #require(window.rootViewController?.view)
            try await waitUntil { accessibilityElement(labeled: Self.sectionName(week: 1, datedAsWeek: 3), in: page) != nil }

            gate.open()
            await loading.value

            try await Self.waitForTopHeader(Self.sectionName(week: 8, datedAsWeek: 3), in: window)
        }
    }
}
#endif
