import SwiftUI
import Testing
@testable import TigerDuck

@MainActor
struct VisualStylePolicyTests {
    private static let tigerDuck = VisualStylePolicy(preset: .default)
    private static let tat = VisualStylePolicy(preset: .tat)

    @Test("TAT keeps TigerDuck's look outside the class table")
    func tatKeepsTigerDucksLook() {
        #expect(Self.tat.courseColorUsage == Self.tigerDuck.courseColorUsage)
        #expect(Self.tat.cardSurface == Self.tigerDuck.cardSurface)
        #expect(Self.tat.chipStyle == Self.tigerDuck.chipStyle)
        #expect(Self.tat.assignmentRowStyle == Self.tigerDuck.assignmentRowStyle)
        #expect(Self.tat.timeSliderActiveSegmentOpacity == Self.tigerDuck.timeSliderActiveSegmentOpacity)
        #expect(Self.tat.timeSliderInactiveSegmentOpacity == Self.tigerDuck.timeSliderInactiveSegmentOpacity)
        #expect(Self.tat.timeSliderUsesCourseColoredThumb == Self.tigerDuck.timeSliderUsesCourseColoredThumb)
        #expect(Self.tat.primaryTextColor == Self.tigerDuck.primaryTextColor)
        #expect(Self.tat.secondaryTextColor == Self.tigerDuck.secondaryTextColor)
    }
}
