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
            #expect(policy.classTableCourseFill(.orange) == Color.orange.opacity(0.3))
            #expect(policy.classTableCourseOutline(.orange) == Color.orange)
            #expect(policy.classTableCourseTextColor == Color.textPrimary)
            #expect(policy.classTableCourseNameWeight == .semibold)
            #expect(policy.classTableCourseSecondaryTextColor == Color.textSecondary)
        }
        #expect(Self.tat.classTableGridStyle == .periodTiles)
        #expect(Self.tat.classTableCourseNameWeight == .medium)
    }

    @Test("The page and its text follow the appearance")
    func tokensFollowTheAppearance() {
        let (light, dark) = (Self.environment(.light), Self.environment(.dark))

        let hex = { (colour: Color, environment: EnvironmentValues) in Color(colour.resolve(in: environment)).rgbHex }

        #expect(hex(.backgroundPrimary, dark) == 0x000000)
        #expect(hex(.textPrimary, dark) == 0xFFFFFF)
        #expect(hex(.backgroundPrimary, light) == 0xF2F2F7)
        #expect(hex(.textPrimary, light) == 0x000000)
    }

    @Test(
        "A course name reads at 10:1 on its translucent block over the dark and the light page",
        arguments: [ColorScheme.dark, .light], TigerDuckTheme.coursePaletteHexes
    )
    func nameOnBlock(scheme: ColorScheme, hex: UInt32) {
        let environment = Self.environment(scheme)
        let fill = Self.tigerDuck.classTableCourseFill(Color(hex: UInt(hex))).resolve(in: environment)
        let page = Color.backgroundPrimary.resolve(in: environment)
        let block = Color.Resolved(
            red: fill.red * fill.opacity + page.red * (1 - fill.opacity),
            green: fill.green * fill.opacity + page.green * (1 - fill.opacity),
            blue: fill.blue * fill.opacity + page.blue * (1 - fill.opacity)
        )

        #expect(Self.contrast(Self.tigerDuck.classTableCourseTextColor, on: block, in: environment) >= 10)
        #expect(Self.contrast(Self.tigerDuck.classTableCourseSecondaryTextColor, on: block, in: environment) >= 4.5)
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

    @Test(
        "The room hint reads on the pastel of every palette colour and of dark picked ones",
        arguments: TigerDuckTheme.coursePaletteHexes + [0x000000, 0x0000FF]
    )
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

    private static func environment(_ scheme: ColorScheme) -> EnvironmentValues {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        return environment
    }

    private static func contrast(
        _ text: Color, on background: Color.Resolved, in environment: EnvironmentValues = EnvironmentValues()
    ) -> Double {
        let ink = text.resolve(in: environment)
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
