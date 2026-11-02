#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct MoreHomeLayoutTests {
    enum Look: String, CaseIterable {
        case light, dark, largestText
    }

    /// The bar caps its text size, so the heading is never narrower than at the default size.
    private static var headingWidthAtDefaultSize: CGFloat {
        UIHostingController(rootView: Text(String(localized: "feature_more"))
            .font(TigerDuckTheme.Typography.title)
            .environment(\.dynamicTypeSize, .large))
            .sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)).width
    }

    @Test("More's heading and gear sit in the bar once each, whole and apart",
          arguments: [375, 402] as [CGFloat], Look.allCases)
    func headingAndGearFit(width: CGFloat, look: Look) async throws {
        try await withAccessibilityAutomation {
            let window = try MoreScreen.window(
                width: width, height: width == 375 ? 812 : 874, style: look == .dark ? .dark : .light,
                textSize: look == .largestText ? .accessibilityExtraExtraExtraLarge : nil,
                settings: EmptyView(), feature: EmptyView()
            )
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            try await waitUntil { MoreScreen.gear(in: window) != nil && !MoreScreen.headings(in: window).isEmpty }
            window.saveSnapshot(as: "more-\(Int(width))-\(look.rawValue)")

            // The walk meets one element through more than one parent.
            let headings = Set(MoreScreen.headings(in: window).map { "\($0.accessibilityFrame)" })
            let heading = try #require(MoreScreen.headings(in: window).first).accessibilityFrame
            let gear = try #require(MoreScreen.gear(in: window)).accessibilityFrame
            let bar = try #require(window.descendants(ofType: UINavigationBar.self).first { !$0.isHidden })
            let barFrame = bar.convert(bar.bounds, to: window).insetBy(dx: -0.5, dy: -0.5)
            #expect(headings.count == 1, "\(headings)")
            #expect(barFrame.contains(heading), "\(heading) outside \(barFrame)")
            #expect(barFrame.contains(gear), "\(gear) outside \(barFrame)")
            #expect(heading.width >= Self.headingWidthAtDefaultSize - 0.5, "\(heading) cut short")
            #expect(heading.maxX < gear.minX, "\(heading) runs into \(gear)")
            #expect(gear.width >= 44 && gear.height >= 44, "\(gear)")
        }
    }
}
#endif
