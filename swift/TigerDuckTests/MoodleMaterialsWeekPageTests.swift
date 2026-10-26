#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
struct MoodleMaterialsWeekPageTests {
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

    private nonisolated static let materials = MoodleCourseMaterials(sections: (0...16).map { week in
        MoodleMaterialSection(
            id: 100 + week, name: week == 0 ? "General" : "Week \(week)", materials: [slides(week: week)], number: week
        )
    })

    /// A weekly course in its eighth week, its materials and details already fetched.
    private static func store(in root: URL) async -> MoodleCourseStore {
        let calendar = AppConstants.taipeiCalendar
        let start = calendar.date(byAdding: .day, value: -7 * 7, to: calendar.startOfDay(for: AppClock.now()))
        let course = MoodleCourseSummary(html: "", text: "", names: [], format: "weeks", startDate: start)
        let cache = DataCache(
            cacheDir: root.appendingPathComponent("cache", isDirectory: true),
            persistentDir: root.appendingPathComponent("persistent", isDirectory: true)
        )
        let store = MoodleCourseStore(
            courseId: 20119,
            termCourseIds: [20119],
            context: MoodleCacheContext(account: "B11399001", cache: cache, isCurrent: { true }),
            api: MoodleCourseAPI(
                functions: { [MoodleCourseContentsService.contentsFunction, MoodleCourseSummaryService.coursesFunction] },
                forums: { _ in [] },
                discussions: { _, _ in [] },
                markViewed: { _, _ in },
                materials: { _ in materials },
                summary: { _ in course }
            ),
            downloads: MoodleFileDownloads(root: cache.moodleFilesDir)
        )
        await store.refreshMaterials()
        await store.refreshSummary()
        return store
    }

    @Test("the materials open at this week's section, whose header alone is marked")
    func opensAtThisWeek() async throws {
        try await withAccessibilityAutomation {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("MoodleMaterialsWeekPageTests-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = await Self.store(in: root)
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.rootViewController = UIHostingController(rootView: NavigationStack {
                MoodleMaterialsView(store: store, policy: VisualStylePolicy(preset: .default))
            })
            window.isHidden = false
            defer { window.isHidden = true }
            let page = try #require(window.rootViewController?.view)

            try await waitUntil {
                accessibilityElement(labeled: "Week 8", in: page).map { $0.accessibilityFrame.minY < window.bounds.height / 3 } ?? false
            }

            let header = try #require(accessibilityElement(labeled: "Week 8", in: page))
            #expect(header.accessibilityTraits.contains(.header))
            #expect(header.accessibilityTraits.contains(.selected))
            let next = try #require(accessibilityElement(labeled: "Week 9", in: page))
            #expect(next.accessibilityTraits.contains(.header))
            #expect(!next.accessibilityTraits.contains(.selected))
        }
    }
}
#endif
