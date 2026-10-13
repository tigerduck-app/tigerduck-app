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

    @Test("TigerDuck and Apple keep the class table's blocks in translucent course colours")
    func classTableBlocks() {
        for preset in [VisualPreset.default, .iosInspired] {
            let policy = VisualStylePolicy(preset: preset)
            #expect(policy.classTableGridStyle == .blocks)
            #expect(policy.classTableCourseFill(.orange) == Color.orange.opacity(0.4))
            #expect(policy.classTableCourseOutline(.orange) == Color.orange)
            #expect(policy.classTableCourseTextColor == Color.textPrimary)
            #expect(policy.classTableCourseSecondaryTextColor == Color.textSecondary)
        }
        #expect(Self.tat.classTableGridStyle == .periodTiles)
    }

    @Test(
        "TAT fills a course with an opaque, lighter pastel of its own hue that dark text reads on",
        arguments: TigerDuckTheme.coursePaletteHexes + [0x000000, 0xFFFFFF, 0x0000FF]
    )
    func pastelFill(hex: UInt32) {
        let colour = Color(hex: UInt(hex)).resolve(in: EnvironmentValues())
        let fill = Self.tat.classTableCourseFill(Color(hex: UInt(hex))).resolve(in: EnvironmentValues())

        #expect(fill.opacity == 1)
        #expect(fill.red >= colour.red && fill.green >= colour.green && fill.blue >= colour.blue)
        if let hue = Self.hue(colour) {
            #expect(abs((Self.hue(fill) ?? -1) - hue) < 0.001)
        }
        #expect(Self.contrast(Self.tat.classTableCourseTextColor, on: fill) >= 7)
    }

    @Test("The room hint reads on the pastel of every palette colour", arguments: TigerDuckTheme.coursePaletteHexes)
    func roomHintOnPastel(hex: UInt32) {
        let fill = Self.tat.classTableCourseFill(Color(hex: UInt(hex))).resolve(in: EnvironmentValues())

        #expect(Self.contrast(Self.tat.classTableCourseSecondaryTextColor, on: fill) >= 4.5)
    }

    @Test(
        "A required course's outline stands out from its pastel",
        arguments: TigerDuckTheme.coursePaletteHexes + [0x000000, 0xFFFFFF, 0x0000FF, 0xFFFF00]
    )
    func outlineOnPastel(hex: UInt32) {
        let colour = Color(hex: UInt(hex))
        let fill = Self.tat.classTableCourseFill(colour).resolve(in: EnvironmentValues())

        #expect(Self.contrast(Self.tat.classTableCourseOutline(colour), on: fill) >= 3)
    }

    /// The HSV hue from 0 up to 1, or nil for a grey, which has none.
    private static func hue(_ colour: Color.Resolved) -> Double? {
        let (red, green, blue) = (Double(colour.red), Double(colour.green), Double(colour.blue))
        let top = max(red, green, blue)
        let spread = top - min(red, green, blue)
        guard spread > 0.0001 else { return nil }
        let sector = if top == red {
            (green - blue) / spread
        } else if top == green {
            (blue - red) / spread + 2
        } else {
            (red - green) / spread + 4
        }
        return sector < 0 ? sector / 6 + 1 : sector / 6
    }

    /// The WCAG contrast ratio of `text`, blended over the opaque `background`.
    private static func contrast(_ text: Color, on background: Color.Resolved) -> Double {
        let ink = text.resolve(in: EnvironmentValues())
        let blended = Color.Resolved(
            red: ink.red * ink.opacity + background.red * (1 - ink.opacity),
            green: ink.green * ink.opacity + background.green * (1 - ink.opacity),
            blue: ink.blue * ink.opacity + background.blue * (1 - ink.opacity)
        )
        let (backgroundLuminance, textLuminance) = (luminance(background), luminance(blended))
        return (max(backgroundLuminance, textLuminance) + 0.05) / (min(backgroundLuminance, textLuminance) + 0.05)
    }

    private static func luminance(_ colour: Color.Resolved) -> Double {
        0.2126 * Double(colour.linearRed) + 0.7152 * Double(colour.linearGreen) + 0.0722 * Double(colour.linearBlue)
    }
}
