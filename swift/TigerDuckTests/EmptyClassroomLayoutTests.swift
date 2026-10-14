#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

/// The finder's dense rows at the largest text sizes, on the narrowest iPhone the app runs on.
@MainActor
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
}
#endif
