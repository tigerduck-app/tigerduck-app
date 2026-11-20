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
                // Due dates rather than "in 2 hours", which the clock moves on between two pictures.
                UpcomingAssignmentsView(
                    assignments: model.assignments.upcoming, policy: policy, filter: model.assignments.filter,
                    showAbsoluteTime: true, asListRows: true
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

    /// The assignment rows the List shows, top to bottom, with the frames their cells are laid out at
    /// in the window.
    static func cells(in window: UIWindow) -> [(title: String, frame: CGRect)] {
        guard let list = window.rootViewController?.view.descendants(ofType: UICollectionView.self).first else { return [] }
        return list.visibleCells.sorted { $0.frame.minY < $1.frame.minY }.compactMap { cell in
            let texts = exposedAccessibilityTexts(in: cell)
            guard let title = titles.first(where: { title in texts.contains { $0.hasPrefix(title) } }) else { return nil }
            return (title, list.convert(cell.frame, to: window))
        }
    }

    static func rows(in window: UIWindow) -> [Row] {
        cells(in: window).map { Row(title: $0.title, top: ($0.frame.minY * 2).rounded() / 2, height: ($0.frame.height * 2).rounded() / 2) }
    }

    /// What the grouped style draws for a row's place in the list: the page showing at its top and
    /// bottom left corners where the container rounds, and the divider along its bottom. The card
    /// style draws every card the same wherever it is, so only its frames show a place.
    struct Decoration: Equatable, CustomStringConvertible {
        let roundedTop: Bool
        let roundedBottom: Bool
        let divider: Bool

        var description: String { "top \(roundedTop ? "round" : "square"), bottom \(roundedBottom ? "round" : "square")\(divider ? ", divider" : "")" }
    }

    static func decorations(in window: UIWindow, policy: VisualStylePolicy) -> [Decoration]? {
        guard policy.assignmentRowStyle == .groupedList else { return nil }
        let picture = window.picture()
        // The page is a light grey, the container white and the divider darker than both.
        let shade = { (x: CGFloat, y: CGFloat) in picture.brightness(at: CGPoint(x: x, y: y)) ?? 0 }
        let corner = TigerDuckTheme.Spacing.lg + 1.5
        let pixel = 1 / picture.scale
        return cells(in: window).map { cell in
            let (top, bottom) = (cell.frame.minY, cell.frame.maxY)
            let bottomLine = stride(from: bottom - pixel / 2, to: bottom - 1, by: -pixel).map { shade(window.bounds.midX, $0) }
            return Decoration(
                roundedTop: shade(corner, top + 1.5) < 0.98 && shade(corner, top + TigerDuckTheme.Spacing.sm + 1.5) < 0.98,
                roundedBottom: shade(corner, bottom - 1.5) < 0.98,
                divider: (bottomLine.min() ?? 1) < 0.9
            )
        }
    }

    struct Settled {
        let rows: [Row]
        let decorations: [Decoration]?
    }

    /// The rows of a List that showed them from the start, and their decorations.
    static func settled(
        _ filter: AssignmentFilter, now: Date, policy: VisualStylePolicy, done: Set<String> = [], savedAs name: String
    ) async throws -> Settled {
        let window = try await show(model(filter, now: now, done: done), policy: policy)
        defer { window.isHidden = true }
        window.saveSnapshot(as: "\(name)-settled")
        let settled = Settled(rows: rows(in: window), decorations: decorations(in: window, policy: policy))
        if let decorations = settled.decorations {
            let count = decorations.count
            let expected = (0..<count).map { Decoration(roundedTop: $0 == 0, roundedBottom: $0 == count - 1, divider: $0 != count - 1) }
            #expect(decorations == expected, "the grouped container as a List that showed its rows from the start draws it")
        }
        return settled
    }

    /// The filter is a `Defaults` setting, which `HomeAssignmentList` writes on each switch.
    static func onHome(_ body: (Date) async throws -> Void) async throws {
        try await withExclusiveRealDefaults {
            let saved = Defaults[.homeAssignmentFilter]
            defer { Defaults[.homeAssignmentFilter] = saved }
            try await withAccessibilityAutomation { try await body(AppClock.now()) }
        }
    }

    /// The List's move and fade, `UpcomingAssignmentsView.listChangeAnimation`, come to rest within
    /// half a second; this leaves room for a busy simulator.
    static let motionEnds = Duration.milliseconds(700)

    static func name(_ policy: VisualStylePolicy, _ change: String) -> String {
        "home-assignment-filter-\(policy.assignmentRowStyle == .card ? "card" : "grouped")-\(change)"
    }

    /// Once the motion is over, the rows and their decorations are the settled list's and stay so.
    static func expectAtRest(
        _ window: UIWindow, as settled: Settled, policy: VisualStylePolicy, savedAs name: String, since start: ContinuousClock.Instant
    ) async throws {
        try await ContinuousClock().sleep(until: start + motionEnds)
        window.saveSnapshot(as: "\(name)-end")
        #expect(rows(in: window) == settled.rows, "\(name) once the motion is over")
        #expect(decorations(in: window, policy: policy) == settled.decorations, "\(name) once the motion is over")
        try await ContinuousClock().sleep(until: start + .seconds(1))
        window.saveSnapshot(as: "\(name)-1s")
        #expect(rows(in: window) == settled.rows, "\(name) a second after the change")
        #expect(decorations(in: window, policy: policy) == settled.decorations, "\(name) a second after the change")
    }

    /// In the first frame the rows already have their settled frames; their content then moves and
    /// fades there with the List's animation.
    @Test("A filter switch lays the rows out in its first frame as they settle", arguments: [VisualPreset.default, .iosInspired])
    func firstFrameIsTheSettledOne(preset: VisualPreset) async throws {
        try await Self.onHome { now in
            let policy = VisualStylePolicy(preset: preset)
            let model = Self.model(.incomplete, now: now)
            let window = try await Self.show(model, policy: policy)
            defer { window.isHidden = true }

            for filter in [AssignmentFilter.all, .incomplete] {
                let name = Self.name(policy, "to-\(filter == .all ? "all" : "incomplete")")
                let settled = try await Self.settled(filter, now: now, policy: policy, savedAs: name)
                #expect(settled.rows.map(\.title) == Self.shown[filter])

                Bindable(model).assignments.filter.wrappedValue = filter
                let start = ContinuousClock.now
                try await waitUntil { Self.rows(in: window).map(\.title) == settled.rows.map(\.title) }
                let first = Self.rows(in: window)
                window.saveSnapshot(as: "\(name)-first")
                #expect(first == settled.rows, "first frame after the switch to \(filter)")
                try await Self.expectAtRest(window, as: settled, policy: policy, savedAs: name, since: start)
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
            let name = Self.name(policy, "ends-leave")
            let settled = try await Self.settled(.incomplete, now: now, policy: policy, done: leaving, savedAs: name)
            #expect(settled.rows.map(\.title) == ["o1", "u1", "u2"].map { "Homework \($0)" })

            Self.markDone(leaving, in: model)
            model.assignments.recompute()
            let start = ContinuousClock.now
            try await waitUntil { Self.rows(in: window).map(\.title) == settled.rows.map(\.title) }
            #expect(Self.rows(in: window) == settled.rows, "first frame after the rows left")
            try await Self.expectAtRest(window, as: settled, policy: policy, savedAs: name, since: start)
        }
    }
}
#endif
