#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

/// The finder's dense rows and its header at the largest text sizes, on the narrowest iPhone the
/// app runs on.
@MainActor
@Suite(.serialized)
struct EmptyClassroomLayoutTests {
    /// A 375 pt iPhone less the inset of the card the rows sit in.
    private static let rowWidth: CGFloat = 375 - 2 * TigerDuckTheme.Spacing.lg
    /// What the availability bar needs to stay readable.
    private static let barWidth: CGFloat = 80

    /// The width of everything in `view` but what can shrink to nothing, such as the bar.
    private static func fixedWidth(_ view: some View, at size: DynamicTypeSize) -> CGFloat {
        let host = UIHostingController(rootView: view.environment(\.dynamicTypeSize, size))
        return host.sizeThatFits(in: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)).width
    }

    @Test("a room's row leaves the bar room at every accessibility size", arguments: [
        DynamicTypeSize.accessibility1, .accessibility3, .accessibility5,
    ])
    func roomRowFits(size: DynamicTypeSize) {
        let room = RoomUsage(room: "HHC-A304", slots: Array(repeating: .free, count: 14))
        let row = RoomRow(room: room, period: 2, ended: 0, policy: VisualStylePolicy(preset: .default), onRoom: { _ in })

        #expect(Self.fixedWidth(row, at: size) <= Self.rowWidth - Self.barWidth)
    }

    /// A finder that never reads, for its header alone.
    private static func idleModel() -> EmptyClassroomViewModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        let service = ClassroomUsageService(
            session: URLSession(configuration: config),
            queryURL: URL(string: "https://cour01.stub.invalid/\(UUID().uuidString)/classroom_usecondition.aspx")!,
            sessionGeneration: { 1 },
            signIn: { _, _, _ in true }
        )
        return EmptyClassroomViewModel(
            service: service, holidays: { _ in [] }, isInSession: { _ in true }, isClassDay: { _ in true },
            courses: { [] }, rawRoom: { $0 }
        )
    }

    /// The title's and the dot's frames in a 375 pt window, nil for a dot left out.
    private static func titleBarFrames(
        showsStatus: Bool, size: DynamicTypeSize = .large
    ) async throws -> (title: CGRect, dot: CGRect?) {
        try await withAccessibilityAutomation {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 375, height: 667)
            let bar = EmptyClassroomTitleBar(viewModel: idleModel(), showsStatus: showsStatus)
            let host = UIHostingController(rootView: VStack(spacing: 0) { bar; Spacer() }
                .environment(\.dynamicTypeSize, size))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }

            let title = String(localized: "feature_empty_classroom")
            try await waitUntil { accessibilityElement(labeled: title, in: host.view) != nil }
            let titleFrame = try #require(accessibilityElement(labeled: title, in: host.view)).accessibilityFrame
            let dot = accessibilityElement(labeled: SyncStatusDot.statusText(.unknown), in: host.view)
            // In screen points, which are the window's: it sits at the screen's origin.
            return (titleFrame, dot?.accessibilityFrame)
        }
    }

    @Test("the title sits at the top left in the pages' title size, with the site's dot on its right")
    func titleBar() async throws {
        let frames = try await Self.titleBarFrames(showsStatus: true)
        let dot = try #require(frames.dot)
        let titleHeight = UIHostingController(
            rootView: Text(String(localized: "feature_empty_classroom")).font(TigerDuckTheme.Typography.title)
        ).sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)).height

        #expect(abs(frames.title.minX - TigerDuckTheme.Spacing.lg) <= 1)
        #expect(abs(frames.title.height - titleHeight) <= 1)
        #expect(abs(dot.maxX - (375 - TigerDuckTheme.Spacing.lg)) <= 1)
        #expect(abs(dot.midY - frames.title.midY) <= 1)
    }

    @Test("signed out the header has no dot")
    func titleBarSignedOut() async throws {
        #expect(try await Self.titleBarFrames(showsStatus: false).dot == nil)
    }

    @Test("at the largest text sizes the title stays clear of the dot and on screen", arguments: [
        DynamicTypeSize.accessibility3, .accessibility5,
    ])
    func titleBarFits(size: DynamicTypeSize) async throws {
        let frames = try await Self.titleBarFrames(showsStatus: true, size: size)
        let dot = try #require(frames.dot)

        #expect(frames.title.maxX <= dot.minX)
        #expect(dot.maxX <= 375)
    }
}
#endif
