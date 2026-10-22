#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct TimeSliderAccessibilityTests {
    @Test func voiceOverSkipsTheTrack() async throws {
        try await withAccessibilityAutomation {
            let anchor = "TimeSliderAccessibilityTests.anchor"
            let host = UIHostingController(rootView: VStack {
                Text(anchor)
                FluidGlassTrackView(viewModel: TimeSliderViewModel()).frame(width: 350)
            })
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            host.view.layoutIfNeeded()

            try await waitUntil { accessibilityElement(labeled: anchor, in: host.view) != nil }
            #expect(Set(exposedAccessibilityLabels(in: host.view)) == [anchor])
        }
    }

    @Test func theTrendSummaryKeepsStillWithReduceMotion() {
        #expect(GPATrendChart.summaryAnimation(reduceMotion: true) == nil)
        #expect(GPATrendChart.summaryAnimation(reduceMotion: false) != nil)
    }
}
#endif
