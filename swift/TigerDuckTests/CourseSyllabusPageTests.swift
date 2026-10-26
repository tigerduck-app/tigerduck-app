#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct CourseSyllabusPageTests {
    private static let syllabus = CourseSyllabus(
        CourseGrading: "Midterm: 30%\nFinal: 40%\nHomework: 30%",
        CourseObject: "Ponds, ducks and the water between them.",
        CourseContent: "Weekly pond walks.",
        CourseTextbook: "Duck Basics",
        CourseRefbook: "Pond Handbook",
        CourseNote: "Bring boots.",
        CoreAbility: "Swim in a straight line.",
        CourseURL: "https://example.ntust.edu.tw/syllabus",
        Instruction_1: "60", Instruction_2: "0", Instruction_3: "20", Instruction_4: "20",
        Instruction_other: "Pond visits"
    )

    @Test("each bar reads as one element that names every part and its percentage", arguments: [
        UIUserInterfaceStyle.light, .dark,
    ])
    func barsReadAsOneElement(style: UIUserInterfaceStyle) async throws {
        try await withAccessibilityAutomation {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 1100)
            window.overrideUserInterfaceStyle = style
            window.rootViewController = UIHostingController(rootView: NavigationStack {
                CourseSyllabusView(syllabus: Self.syllabus, policy: VisualStylePolicy(preset: .default))
            })
            window.isHidden = false
            defer { window.isHidden = true }
            let root = try #require(window.rootViewController?.view)
            let grading = Self.spoken([("Midterm", 30), ("Final", 40), ("Homework", 30)])
            let teaching = Self.spoken([
                (String(localized: "course_detail_syllabus_lecture"), 60),
                (String(localized: "course_detail_syllabus_case_study"), 20),
                (String(localized: "course_detail_syllabus_practical"), 20),
            ])

            try await waitUntil { accessibilityElement(labeled: grading, in: root) != nil }

            #expect(accessibilityElement(labeled: teaching, in: root) != nil)
            try await Task.sleep(for: .milliseconds(400))
            Self.save(window, as: "course-syllabus-\(style == .dark ? "dark" : "light")")
        }
    }

    private static func spoken(_ parts: [(String, Double)]) -> String {
        parts.map { "\($0.0) \(($0.1 / 100).formatted(.percent))" }.formatted()
    }

    /// Keeps a picture of the page for a person to look at, when the checkout has a `.out` folder;
    /// CI's has none.
    private static func save(_ window: UIWindow, as name: String, file: String = #filePath) {
        let out = URL(filePath: file).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: ".out")
        guard FileManager.default.fileExists(atPath: out.path(percentEncoded: false)) else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: out.appending(path: "\(name).png"))
    }
}
#endif
