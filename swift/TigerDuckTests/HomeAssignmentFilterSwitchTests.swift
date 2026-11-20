#if os(iOS)
import Defaults
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct HomeAssignmentFilterSwitchTests {
    @Observable final class Model {
        var assignments = HomeAssignmentList()
    }

    /// Home's assignment section as `HomeBrowsePage` and `HomeSectionView` lay it out; both read an
    /// `AppEnvironment`, which the test host never builds.
    struct Section: View {
        let model: Model
        let policy: VisualStylePolicy

        var body: some View {
            List {
                Picker("", selection: Bindable(model).assignments.filter) {
                    ForEach(model.assignments.availableFilters, id: \.self) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .homeListRow(top: TigerDuckTheme.Spacing.sm)
                UpcomingAssignmentsView(
                    assignments: model.assignments.upcoming, policy: policy, filter: model.assignments.filter,
                    asListRows: true
                )
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .animation(UpcomingAssignmentsView.listChangeAnimation, value: model.assignments.upcoming.map(\.assignmentId))
            .background(Color.backgroundPrimary)
        }
    }

    struct Row: Equatable, CustomStringConvertible {
        let title: String
        let top: CGFloat
        let height: CGFloat

        var description: String { "\(title) at \(top), \(height) high" }
    }

    /// Unfinished, overdue, submitted, marked done and ignored, over three courses. The two
    /// filters order the overdue ones differently, so a switch moves rows as well as adding them.
    static func fixtures(now: Date) -> [SDAssignment] {
        let hour: TimeInterval = 3600
        func make(
            _ id: String, _ course: String, due hours: Double, completed: Bool = false, archived: Bool = false,
            done: Bool = false, cutoff: Double? = nil
        ) -> SDAssignment {
            SDAssignment(
                assignmentId: id, courseNo: course, courseName: "Course \(course)", title: "Homework \(id)",
                dueDate: now + hours * hour, isCompleted: completed, isArchived: archived, isLocallyCompleted: done,
                cutoffDate: cutoff.map { now + $0 * hour }
            )
        }
        return [
            make("u1", "CS1", due: 2),
            make("c2", "CS1", due: -48, completed: true),
            make("u2", "EE2", due: 24),
            make("o1", "CS1", due: -24),
            make("c1", "MA3", due: 48, completed: true),
            make("u3", "MA3", due: 72),
            make("o2", "EE2", due: -72, cutoff: -1),
            make("l1", "EE2", due: 96, done: true),
            make("a1", "MA3", due: 120, archived: true),
        ]
    }

    static let titles = ["u1", "c2", "u2", "o1", "c1", "u3", "o2", "l1", "a1"].map { "Homework \($0)" }

    /// Each filter's rows, top to bottom: unfinished by due date; everything not ignored, the
    /// upcoming ones first and then the past ones from the latest.
    static let shown: [AssignmentFilter: [String]] = [
        .incomplete: ["o2", "o1", "u1", "u2", "u3"].map { "Homework \($0)" },
        .all: ["u1", "u2", "c1", "u3", "l1", "o1", "c2", "o2"].map { "Homework \($0)" },
    ]

    static func model(_ filter: AssignmentFilter, now: Date, done: Set<String> = []) -> Model {
        let model = Model()
        model.assignments.all = fixtures(now: now)
        markDone(done, in: model)
        model.assignments.filter = filter
        model.assignments.recompute()
        return model
    }

    static func markDone(_ ids: Set<String>, in model: Model) {
        for assignment in model.assignments.all where ids.contains(assignment.assignmentId) {
            assignment.isLocallyCompleted = true
        }
    }

    /// A 375 pt window tall enough that nothing scrolls, once the List has laid its rows out.
    static func show(_ model: Model, policy: VisualStylePolicy) async throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 1100)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = UIHostingController(rootView: Section(model: model, policy: policy))
        window.isHidden = false
        let count = model.assignments.upcoming.count
        try await waitUntil { rows(in: window).count == count }
        try await Task.sleep(for: .milliseconds(300))
        return window
    }

    /// The assignment rows the List shows, top to bottom, by the frames their cells are laid out at.
    static func rows(in window: UIWindow) -> [Row] {
        let cells = window.rootViewController?.view.descendants(ofType: UICollectionView.self).first?.visibleCells ?? []
        return cells.sorted { $0.frame.minY < $1.frame.minY }.compactMap { cell in
            let texts = exposedAccessibilityTexts(in: cell)
            guard let title = titles.first(where: { title in texts.contains { $0.hasPrefix(title) } }) else { return nil }
            return Row(title: title, top: (cell.frame.minY * 2).rounded() / 2, height: (cell.frame.height * 2).rounded() / 2)
        }
    }

    /// The rows of a List that showed them from the start.
    static func freshRows(_ filter: AssignmentFilter, now: Date, policy: VisualStylePolicy, done: Set<String> = []) async throws -> [Row] {
        let window = try await show(model(filter, now: now, done: done), policy: policy)
        defer { window.isHidden = true }
        return rows(in: window)
    }

    /// The filter is a `Defaults` setting, which `HomeAssignmentList` writes on each switch.
    static func onHome(_ body: (Date) async throws -> Void) async throws {
        try await withExclusiveRealDefaults {
            let saved = Defaults[.homeAssignmentFilter]
            defer { Defaults[.homeAssignmentFilter] = saved }
            try await withAccessibilityAutomation { try await body(AppClock.now()) }
        }
    }

    @Test("A filter switch lays the rows out in its first frame as they settle", arguments: [VisualPreset.default, .iosInspired])
    func firstFrameIsTheSettledOne(preset: VisualPreset) async throws {
        try await Self.onHome { now in
            let policy = VisualStylePolicy(preset: preset)
            let style = policy.assignmentRowStyle == .card ? "card" : "grouped"
            let model = Self.model(.incomplete, now: now)
            let window = try await Self.show(model, policy: policy)
            defer { window.isHidden = true }

            for filter in [AssignmentFilter.all, .incomplete] {
                let settled = try await Self.freshRows(filter, now: now, policy: policy)
                #expect(settled.map(\.title) == Self.shown[filter])
                let name = "home-assignment-filter-\(style)-to-\(filter == .all ? "all" : "incomplete")"

                Bindable(model).assignments.filter.wrappedValue = filter
                try await waitUntil { Self.rows(in: window).map(\.title) == settled.map(\.title) }
                let first = Self.rows(in: window)
                window.saveSnapshot(as: "\(name)-first")
                #expect(first == settled, "first frame after the switch to \(filter)")

                try await Task.sleep(for: .milliseconds(400))
                window.saveSnapshot(as: "\(name)-animated")
                try await Task.sleep(for: .milliseconds(600))
                window.saveSnapshot(as: "\(name)-1s")
                #expect(Self.rows(in: window) == settled, "a second after the switch to \(filter)")
            }
        }
    }

    /// A refresh and a swipe's mark both change the assignments and work the list out again.
    @Test("A row that leaves the top or the bottom hands its place's spacing on in the first frame", arguments: [VisualPreset.default, .iosInspired])
    func rowsLeavingTheEnds(preset: VisualPreset) async throws {
        try await Self.onHome { now in
            let policy = VisualStylePolicy(preset: preset)
            let model = Self.model(.incomplete, now: now)
            let window = try await Self.show(model, policy: policy)
            defer { window.isHidden = true }
            let leaving: Set<String> = ["o2", "u3"]
            let settled = try await Self.freshRows(.incomplete, now: now, policy: policy, done: leaving)
            #expect(settled.map(\.title) == ["o1", "u1", "u2"].map { "Homework \($0)" })

            Self.markDone(leaving, in: model)
            model.assignments.recompute()
            try await waitUntil { Self.rows(in: window).map(\.title) == settled.map(\.title) }
            #expect(Self.rows(in: window) == settled)
        }
    }
}
#endif
