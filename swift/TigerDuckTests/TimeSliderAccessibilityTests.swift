#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

/// VoiceOver skips the time slider's track, whose time-only value was hard to follow
/// (https://github.com/tigerduck-app/tigerduck-app/issues/570), and Score's trend summary keeps
/// still with Reduce Motion on (https://github.com/tigerduck-app/tigerduck-app/issues/525).
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

            // The text beside the track is exposed in the same pass the track would be.
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
