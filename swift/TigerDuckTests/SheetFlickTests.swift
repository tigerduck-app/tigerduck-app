#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct SheetFlickTests {
    struct Drag: CustomTestStringConvertible {
        let speed: CGFloat
        let travel: CGFloat
        var startedAtTop = true
        var isLarge = true
        let closes: Bool

        var testDescription: String {
            "\(Int(speed)) pt/s over \(Int(travel)) pt\(startedAtTop ? "" : ", scrolled")\(isLarge ? "" : ", medium") → \(closes)"
        }
    }

    static let drags = [
        Drag(speed: SheetFlick.minimumSpeed, travel: SheetFlick.minimumTravel, closes: true),
        Drag(speed: 3_000, travel: 300, closes: true),
        Drag(speed: SheetFlick.minimumSpeed - 1, travel: 300, closes: false),
        Drag(speed: 3_000, travel: SheetFlick.minimumTravel - 1, closes: false),
        Drag(speed: -3_000, travel: -300, closes: false),
        Drag(speed: 3_000, travel: 300, startedAtTop: false, closes: false),
        Drag(speed: 3_000, travel: 300, isLarge: false, closes: false),
    ]

    @Test("a drag closes the sheet only from the large detent and the content's top, fast and far enough", arguments: drags)
    func decision(drag: Drag) {
        #expect(SheetFlick.closesSheet(
            speed: drag.speed, travel: drag.travel, startedAtTop: drag.startedAtTop, isLarge: drag.isLarge
        ) == drag.closes)
    }

    @Observable
    final class Probe {
        var isPresented = true
        var isShown = false
        var detent: PresentationDetent

        init(detent: PresentationDetent) { self.detent = detent }
    }

    struct Sheet: View {
        @Bindable var probe: Probe
        let flicks: Bool
        let startsAtBottom: Bool

        var body: some View {
            Color.clear.sheet(isPresented: $probe.isPresented) {
                ScrollView { SheetFlickTests.rows }
                .defaultScrollAnchor(startsAtBottom ? .bottom : .top)
                .flickClosesSheet(at: flicks ? probe.detent : .medium)
                .presentationDetents([.medium, .large], selection: $probe.detent)
                .onAppear { probe.isShown = true }
            }
        }
    }

    static var rows: some View {
        LazyVStack {
            ForEach(0..<200, id: \.self) { Text(verbatim: "Row \($0)").frame(maxWidth: .infinity, minHeight: 44) }
        }
    }

    @Observable
    final class Stack {
        var isPresented = true
        var isShown = false
        var path: [Int] = []
        var detent: PresentationDetent = .large
    }

    /// Laid out as `CourseDetailSheet` is, which reads an `AppEnvironment` the test host never builds.
    struct CourseSheet: View {
        @Bindable var stack: Stack

        var body: some View {
            Color.clear.sheet(isPresented: $stack.isPresented) {
                NavigationStack(path: $stack.path) {
                    ScrollView { SheetFlickTests.rows }
                        .courseDetailRootBar()
                        .flickClosesSheet(at: stack.detent)
                        .navigationDestination(for: Int.self) { _ in
                            List(0..<200, id: \.self) { Text(verbatim: "Announcement \($0)") }
                        }
                }
                .presentationDetents([.medium, .large], selection: $stack.detent)
                .onAppear { stack.isShown = true }
            }
        }
    }

    @Test("on the course sheet a flick closes it from its root page, and a pushed page keeps UIKit's behaviour", arguments: [false, true])
    func courseSheet(pushed: Bool) async throws {
        let stack = Stack()
        let window = try ClubScreensTests.show(CourseSheet(stack: stack), look: ClubScreensTests.looks[0], width: 402, height: 874)
        defer {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
        }
        try await waitUntil { stack.isShown }
        try await Task.sleep(for: .seconds(1))
        if pushed {
            stack.path.append(1)
            try await Task.sleep(for: .seconds(1))
        }

        try await Self.drag(in: window, over: .milliseconds(90), from: 300)
        if pushed {
            try await waitUntil { stack.detent == .medium || !stack.isPresented }
            #expect(stack.isPresented)
            #expect(stack.path.count == 1)
        } else {
            try await waitUntil { !stack.isPresented }
        }
    }

    static func present(from detent: PresentationDetent, flicks: Bool = true, startsAtBottom: Bool = false) async throws -> (Probe, UIWindow) {
        let probe = Probe(detent: detent)
        let window = try ClubScreensTests.show(
            Sheet(probe: probe, flicks: flicks, startsAtBottom: startsAtBottom), look: ClubScreensTests.looks[0],
            width: 402, height: 874
        )
        try await waitUntil { probe.isShown }
        try await Task.sleep(for: .seconds(1))
        return (probe, window)
    }

    static func drag(in window: UIWindow, over duration: Duration, from top: CGFloat = 520) async throws {
        window.makeKeyAndVisible()
        try await fingerDrag(from: CGPoint(x: 201, y: top), to: CGPoint(x: 201, y: top + 300), over: duration, in: window)
    }

    /// Only for an outcome where nothing happens, which no condition can wait for.
    static func settle() async throws {
        try await Task.sleep(for: .seconds(1.5))
    }

    @Test("a fast flick down from the large detent closes the sheet in one go")
    func flickFromLarge() async throws {
        let (probe, window) = try await Self.present(from: .large)
        defer { window.isHidden = true }

        try await Self.drag(in: window, over: .milliseconds(90), from: 300)
        try await waitUntil { !probe.isPresented }
    }

    @Test("without the flick, UIKit settles the same flick at the medium detent")
    func uikitSettlesAtMedium() async throws {
        let (probe, window) = try await Self.present(from: .large, flicks: false)
        defer {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
        }

        try await Self.drag(in: window, over: .milliseconds(90), from: 300)
        try await waitUntil { probe.detent == .medium || !probe.isPresented }
        #expect(probe.isPresented)
    }

    @Test("a slow drag down from the large detent settles at the medium one")
    func slowDragFromLarge() async throws {
        let (probe, window) = try await Self.present(from: .large)
        defer {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
        }

        try await Self.drag(in: window, over: .milliseconds(1_500), from: 300)
        try await waitUntil { probe.detent == .medium || !probe.isPresented }
        #expect(probe.isPresented)
    }

    @Test("a fast flick down on content scrolled away from its top scrolls it and keeps the sheet")
    func flickOnScrolledContent() async throws {
        let (probe, window) = try await Self.present(from: .large, startsAtBottom: true)
        defer {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
        }

        try await Self.drag(in: window, over: .milliseconds(90), from: 300)
        try await Self.settle()
        #expect(probe.isPresented)
        #expect(probe.detent == .large)
    }

    @Observable
    final class Presence {
        var isPresented = true
    }

    struct DetailSheet: View {
        @Bindable var presence: Presence
        let content: AnyView

        var body: some View {
            Color.clear.sheet(isPresented: $presence.isPresented) { content }
        }
    }

    @Test("the club and grades course sheets, once dragged up to large, close on a flick", arguments: ["club", "score"])
    func detailSheets(kind: String) async throws {
        try await withAccessibilityAutomation {
            let folder = ScoreCourseSheetScreenTests.Folder()
            defer { folder.remove() }
            let club = try CopyToastScreenTests.club(at: "TR-313")
            let content = kind == "club"
                ? AnyView(ClubActivityDetailSheet(club: club, policy: CopyToastScreenTests.policy))
                : AnyView(ScoreCourseSheetScreenTests.sheet(ScoreCourseSheetScreenTests.grade(), roster: nil, in: folder))
            let presence = Presence()
            let window = try ClubScreensTests.show(
                DetailSheet(presence: presence, content: content), look: ClubScreensTests.looks[0], width: 402, height: 874
            )
            defer { window.isHidden = true }
            _ = try await CopyToastScreenTests.element(kind == "club" ? club.clubName : ScoreCourseSheetScreenTests.termText, in: window)
            try await Task.sleep(for: .seconds(1))

            window.makeKeyAndVisible()
            try await fingerDrag(from: CGPoint(x: 201, y: 760), to: CGPoint(x: 201, y: 260), over: .milliseconds(800), in: window)
            try await Task.sleep(for: .seconds(1.5))
            #expect(presence.isPresented)

            try await Self.drag(in: window, over: .milliseconds(90), from: 300)
            try await waitUntil { !presence.isPresented }
        }
    }

    @Test("a drag down from the medium detent closes the sheet as before")
    func dragFromMedium() async throws {
        let (probe, window) = try await Self.present(from: .medium)
        defer { window.isHidden = true }

        try await Self.drag(in: window, over: .milliseconds(600))
        try await waitUntil { !probe.isPresented }
    }
}
#endif
