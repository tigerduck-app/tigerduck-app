#if os(iOS)
import SwiftUI
import Testing
import TigerDuckCore
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct TodayCourseCardLayoutTests {
    @Test("today's course card keeps its room and time whole at 375 points and the largest text")
    func roomAndTimeStayWhole() async throws {
        try await withAccessibilityAutomation {
            let course = SDCourse(
                courseNo: "TEST430", courseName: "計算機網路實驗", classroom: "TR-313",
                schedule: Dictionary(uniqueKeysWithValues: (1...7).map { ($0, ["3", "4"]) })
            )
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 375, height: 812)
            window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            window.rootViewController = UIHostingController(rootView: ScrollView {
                TodayCourseCarousel(courses: [course], hasAssignment: { _ in false }, showProgress: false)
            }.environment(\.locale, Locale(identifier: "zh-Hant-TW")))
            window.makeKeyAndVisible()
            defer { window.isHidden = true }

            try await waitUntil { Self.card(named: course.courseName, in: window) != nil }
            try await Task.sleep(for: .milliseconds(400))
            let language = Bundle.main.preferredLocalizations.first ?? "en"
            window.saveSnapshot(as: "today-course-card-375-largest-\(language)")

            let shown = try #require(Self.card(named: course.courseName, in: window))
            let needed = UIHostingController(
                rootView: TodayCourseCard(course: course).environment(\.dynamicTypeSize, .accessibility5)
            ).sizeThatFits(in: CGSize(width: 375, height: CGFloat.greatestFiniteMagnitude))
            #expect(shown.accessibilityFrame.height >= needed.height - 0.5, "\(shown.accessibilityFrame) for \(needed)")
            #expect(shown.accessibilityFrame.maxX <= window.bounds.maxX, "\(shown.accessibilityFrame)")
            #expect(shown.accessibilityLabel?.contains("TR-313") == true)
            #expect(shown.accessibilityLabel?.contains(TimeRange.spoken("10:20", "12:10")) == true)
        }
    }

    private static func card(named name: String, in window: UIWindow) -> NSObject? {
        exposedAccessibilityElements(in: window).first { $0.accessibilityLabel?.contains(name) == true }
    }
}
#endif
