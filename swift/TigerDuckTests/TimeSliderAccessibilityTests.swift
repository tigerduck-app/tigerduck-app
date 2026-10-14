#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

/// VoiceOver cannot drag the time slider's track, so the track is one adjustable element, and
/// Score's trend summary keeps still with Reduce Motion on
/// (https://github.com/tigerduck-app/tigerduck-app/issues/525).
@MainActor
@Suite(.serialized)
struct TimeSliderAccessibilityTests {
    @Test func voiceOverMovesTheTimeAQuarterHourAtATime() async throws {
        try await withAccessibilityAutomation {
            let model = TimeSliderViewModel()
            let start = model.selectedTime
            let track = FluidGlassTrackView(viewModel: model, timeText: "10:00").frame(width: 350)
            let host = UIHostingController(rootView: track)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            host.view.layoutIfNeeded()

            let label = String(localized: "home_time_slider_title")
            try await waitUntil { accessibilityElement(labeled: label, in: host.view) != nil }
            let element = try #require(accessibilityElement(labeled: label, in: host.view))
            #expect(element.accessibilityTraits.contains(.adjustable))
            #expect(element.accessibilityValue == "10:00")

            element.accessibilityIncrement()
            #expect(model.selectedTime == start.addingTimeInterval(15 * 60))
            #expect(model.isUserDragging)
            element.accessibilityDecrement()
            element.accessibilityDecrement()
            #expect(model.selectedTime == start.addingTimeInterval(-15 * 60))

            let nowName = String(localized: "home_time_slider_now")
            let now = try #require(element.accessibilityCustomActions?.first { $0.name == nowName })
            if let handler = now.actionHandler {
                _ = handler(now)
            } else {
                _ = (now.target as? NSObject)?.perform(now.selector, with: now)
            }
            try await waitUntil { !model.isUserDragging }
        }
    }

    @Test func theTrendSummaryKeepsStillWithReduceMotion() {
        #expect(GPATrendChart.summaryAnimation(reduceMotion: true) == nil)
        #expect(GPATrendChart.summaryAnimation(reduceMotion: false) != nil)
    }
}
#endif
