#if os(iOS)
import SwiftUI
import Testing
import TigerDuckCore
import UIKit
import WidgetKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct WidgetSnapshotPictureTests {
    private typealias Fixtures = WidgetFixtures

    struct Look: CustomTestStringConvertible, Sendable {
        let name: String
        let style: UIUserInterfaceStyle
        var tinted = false
        var textSize: UIContentSizeCategory = .large
        var long = false

        var testDescription: String { name }
        var renderingMode: WidgetRenderingMode { tinted ? .accented : .fullColor }
    }

    static let looks = [
        Look(name: "light", style: .light),
        Look(name: "dark", style: .dark),
        Look(name: "tinted", style: .dark, tinted: true),
        Look(name: "largest", style: .light, textSize: .accessibilityExtraExtraExtraLarge),
        Look(name: "long", style: .light, long: true),
        Look(name: "long-largest-dark", style: .dark, textSize: .accessibilityExtraExtraExtraLarge, long: true),
    ]

    enum Shot: String, CaseIterable, Sendable {
        case nextSmall, nextSmallBetween, nextMedium, nextMediumBetween, todayMedium, todayLarge, todayPortrait, todayPortraitBetween
        case todayExtraLarge, todayExtraLargeMini, todayExtraLargePro13
        case weekLarge, weekPortrait, weekExtraLarge, weekExtraLargeMini, weekExtraLargePro13
        case lockInline, lockCircular, lockRectangular
    }

    private static var language: String { Bundle.main.preferredLocalizations.first ?? "en" }

    private static func family(of shot: Shot) -> WidgetFamily? {
        switch shot {
        case .nextSmall, .nextSmallBetween: .systemSmall
        case .nextMedium, .nextMediumBetween, .todayMedium: .systemMedium
        case .todayLarge, .weekLarge: .systemLarge
        case .todayExtraLarge, .todayExtraLargeMini, .todayExtraLargePro13, .weekExtraLarge, .weekExtraLargeMini, .weekExtraLargePro13:
            .systemExtraLarge
        case .todayPortrait, .todayPortraitBetween, .weekPortrait:
            WidgetFamily.withExtraLargePortrait([]).first
        case .lockInline: .accessoryInline
        case .lockCircular: .accessoryCircular
        case .lockRectangular: .accessoryRectangular
        }
    }

    /// Sizes from https://developer.apple.com/design/human-interface-guidelines/widgets#iOS-dimensions
    /// for a 375 pt phone and https://developer.apple.com/design/human-interface-guidelines/widgets#iPadOS-dimensions
    /// for the iPad canvas: 11-inch, mini and 13-inch. The tables list extra large portrait only for
    /// visionOS, so its phone size is the large one grown by the large-to-medium step.
    private static func size(of shot: Shot, family: WidgetFamily) -> CGSize {
        switch shot {
        case .todayExtraLargeMini, .weekExtraLargeMini: return CGSize(width: 634.5, height: 305.5)
        case .todayExtraLargePro13, .weekExtraLargePro13: return CGSize(width: 860, height: 412)
        default: break
        }
        return switch family {
        case .systemSmall: CGSize(width: 155, height: 155)
        case .systemMedium: CGSize(width: 329, height: 155)
        case .systemLarge: CGSize(width: 329, height: 345)
        case .systemExtraLarge: CGSize(width: 715.5, height: 342)
        case .accessoryInline: CGSize(width: 225, height: 26)
        case .accessoryCircular: CGSize(width: 72, height: 72)
        case .accessoryRectangular: CGSize(width: 157, height: 72)
        default: WidgetLayoutTests.portrait
        }
    }

    @Test(arguments: Shot.allCases, looks)
    func picture(of shot: Shot, look: Look) async throws {
        guard let family = Self.family(of: shot) else { return }
        try await withAccessibilityAutomation {
            let snapshot = Fixtures.snapshot(courses: Fixtures.week(long: look.long))
            let between = [.nextSmallBetween, .nextMediumBetween, .todayPortraitBetween].contains(shot)
            let now = between ? Fixtures.wednesday(12, 40) : Fixtures.wednesday(11, 32)
            let palette = WidgetPalette.resolve(
                snapshot: snapshot, colorScheme: look.style == .dark ? .dark : .light, renderingMode: look.renderingMode
            )
            let derived = WidgetTimelineDerivation.derive(snapshot: snapshot, at: now)
            let (view, background, margins) = Self.content(of: shot, family: family, snapshot: snapshot, now: now, palette: palette, derived: derived)
            let window = try WidgetLayoutTests.Host.show(
                view, size: Self.size(of: shot, family: family), style: look.style, textSize: look.textSize,
                renderingMode: look.renderingMode, background: background, margins: margins
            )
            defer { window.isHidden = true }
            let expected = shot == .nextSmallBetween || shot == .nextMediumBetween ? "計算機網路概論" : look.long ? "IB-505" : "TR-412"
            try await waitUntil { exposedAccessibilityTexts(in: window).contains { $0.contains(expected) } }
            try await Task.sleep(for: .milliseconds(300))
            window.saveSnapshot(as: "widget-\(shot.rawValue)-\(look.name)-\(Self.language)")
        }
    }

    private static func content(
        of shot: Shot, family: WidgetFamily, snapshot: WidgetSnapshot, now: Date, palette: WidgetPalette,
        derived: WidgetDerivedState
    ) -> (AnyView, Color?, CGFloat) {
        switch shot {
        case .nextSmall, .nextSmallBetween:
            let background = NextClassSmallView.background(of: derived, palette: palette)
            return (AnyView(NextClassView(derived: derived, palette: palette, family: family)), background, 14)
        case .nextMedium, .nextMediumBetween:
            let upNext = WidgetTimelineDerivation.upNext(snapshot: snapshot, at: now, after: derived)
            let view = NextClassView(derived: derived, upNext: upNext, palette: palette, family: family, clock: now)
            return (AnyView(view), palette.canvas, 11)
        case .todayMedium, .todayLarge, .todayPortrait, .todayPortraitBetween, .todayExtraLarge, .todayExtraLargeMini,
             .todayExtraLargePro13:
            return (AnyView(TodayView(snapshot: snapshot, now: now, palette: palette, family: family)), palette.canvas, 16)
        case .weekLarge, .weekPortrait, .weekExtraLarge, .weekExtraLargeMini, .weekExtraLargePro13:
            let view = WeekGridView(snapshot: snapshot, now: now, palette: palette, family: family)
            return (AnyView(view), palette.canvas, family == .systemLarge ? 8 : 10)
        case .lockInline:
            return (AnyView(AccessoryInlineView(derived: derived).foregroundStyle(.white)), .clear, 0)
        case .lockCircular:
            return (AnyView(AccessoryCircularView(derived: derived).foregroundStyle(.white)), .white.opacity(0.16), 0)
        case .lockRectangular:
            return (AnyView(AccessoryRectangularView(derived: derived).foregroundStyle(.white)), .clear, 0)
        }
    }
}
#endif
