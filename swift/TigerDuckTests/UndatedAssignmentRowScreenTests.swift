#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct UndatedAssignmentRowScreenTests {
    private static let now = Date(timeIntervalSince1970: 1_790_600_000)
    private static let looks = ClubScreensTests.looks
        + [ClubScreensTests.Look(style: .dark, textSize: .accessibilityExtraExtraExtraLarge)]

    private static func assignment(_ id: String, _ title: String, due offset: TimeInterval?) -> SDAssignment {
        SDAssignment(
            assignmentId: id, courseNo: "CS3105301", courseName: "Data Structures", title: title,
            dueDate: offset.map { now + $0 }
        )
    }

    /// Home's card rows, each a button as in Home's list.
    private static func list(_ assignments: [SDAssignment]) -> some View {
        let course = SDCourse(courseNo: "CS3105301", courseName: "Data Structures")
        return ScrollView {
            VStack(spacing: TigerDuckTheme.Spacing.sm) {
                ForEach(assignments.upcomingSorted(), id: \.assignmentId) { assignment in
                    Button {} label: {
                        UpcomingAssignmentRow(
                            assignment: assignment, course: course, now: now,
                            policy: VisualStylePolicy(preset: .default), showAbsoluteTime: false
                        )
                        .cardPadding()
                        .glassCard()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                }
            }
            .padding(.vertical, TigerDuckTheme.Spacing.lg)
        }
        .background(Color.backgroundPrimary)
    }

    private static func row(_ title: String, in window: UIWindow) -> NSObject? {
        exposedAccessibilityElements(in: window).first { $0.accessibilityLabel?.contains(title) == true }
    }

    @Test("Home lists an undated assignment last, with a dash for its time that VoiceOver does not read",
          arguments: looks)
    func undatedRowComesLastWithADash(look: ClubScreensTests.Look) async throws {
        try await withAccessibilityAutomation {
            let dated = Self.assignment("701", "HW 2: Linked lists", due: 2 * 3_600)
            let page = Self.list([
                Self.assignment("703", "Reading notes for the whole term", due: nil),
                dated,
                Self.assignment("702", "Lab 3", due: -3_600),
            ])
            let window = try ClubScreensTests.show(page, look: look, height: look.textSize == .large ? 812 : 2400)
            defer { window.isHidden = true }
            try await waitUntil { Self.row("Reading notes", in: window) != nil }
            try await Task.sleep(for: .milliseconds(400))
            let language = Bundle.main.preferredLocalizations.first ?? "en"
            window.saveSnapshot(as: "home-undated-assignment-\(look.testDescription)-\(language)")

            let undated = try #require(Self.row("Reading notes", in: window))
            let shownDated = try #require(Self.row("HW 2", in: window))
            let past = try #require(Self.row("Lab 3", in: window))
            #expect(past.accessibilityFrame.maxY <= shownDated.accessibilityFrame.minY + 0.5)
            #expect(shownDated.accessibilityFrame.maxY <= undated.accessibilityFrame.minY + 0.5)
            #expect(undated.accessibilityFrame.maxX <= window.bounds.maxX + 0.5, "\(undated.accessibilityFrame)")
            #expect(undated.accessibilityLabel?.contains("Data Structures") == true)
            #expect(undated.accessibilityLabel?.contains("\u{2014}") == false, "\(undated.accessibilityLabel ?? "")")
            #expect(
                shownDated.accessibilityLabel?.contains(dated.dueLabel(now: Self.now, absolute: false)) == true,
                "\(shownDated.accessibilityLabel ?? "")"
            )
        }
    }
}
#endif
