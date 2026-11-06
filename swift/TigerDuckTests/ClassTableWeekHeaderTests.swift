#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct ClassTableWeekHeaderTests {
    struct Look: CustomTestStringConvertible {
        let style: UIUserInterfaceStyle
        let textSize: UIContentSizeCategory
        let drawsPeriodTiles: Bool
        var weekdays = Array(1...5)

        var testDescription: String {
            [
                style == .dark ? "dark" : "light", textSize == .large ? "default" : "largest",
                drawsPeriodTiles ? "tiles" : "blocks", "\(weekdays.count)days",
            ].joined(separator: "-")
        }
    }

    /// W12 is tightest over the tiles' narrow period column, and the weekday names in the seven
    /// columns the weekend leaves beside the blocks' wide one.
    static let looks = [
        Look(style: .light, textSize: .large, drawsPeriodTiles: false),
        Look(style: .dark, textSize: .large, drawsPeriodTiles: true),
        Look(style: .light, textSize: .accessibilityExtraExtraExtraLarge, drawsPeriodTiles: false, weekdays: Array(1...7)),
        Look(style: .dark, textSize: .accessibilityExtraExtraExtraLarge, drawsPeriodTiles: true),
    ]

    private static let padding = TigerDuckTheme.Spacing.xs
    private static let spokenWeek = String(format: String(localized: "a11y_class_table_week"), 12)
    private static var language: String { Bundle.main.preferredLocalizations.first ?? "en" }

    private static func labels(of look: Look) -> [String] {
        look.weekdays.map { AppConstants.Periods.shortWeekdayLabel($0) }
    }

    private static func show(week: Int?, look: Look) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 200)
        window.overrideUserInterfaceStyle = look.style
        window.traitOverrides.preferredContentSizeCategory = look.textSize
        let header = TimetableHeaderRow(weekdays: look.weekdays, today: 3, week: week, drawsPeriodTiles: look.drawsPeriodTiles)
            .padding(.horizontal, padding)
            .padding(.top, TigerDuckTheme.Spacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.backgroundPrimary)
        window.rootViewController = UIHostingController(rootView: header)
        window.makeKeyAndVisible()
        return window
    }

    private static func frames(of look: Look, in window: UIWindow) async throws -> [CGRect] {
        let labels = Self.labels(of: look)
        try await waitUntil { labels.allSatisfy { accessibilityElement(labeled: $0, in: window) != nil } }
        try await Task.sleep(for: .milliseconds(400))
        return try labels.map { try #require(accessibilityElement(labeled: $0, in: window)).accessibilityFrame }
    }

    /// The width of `text` in the header's font, on one line at the look's text size.
    private static func idealWidth(_ text: String, _ look: Look) -> CGFloat {
        let size = DynamicTypeSize(look.textSize) ?? .large
        return UIHostingController(rootView: Text(text).font(TimetableHeaderRow.font).environment(\.dynamicTypeSize, size))
            .sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)).width
    }

    /// A label cut off is as wide as its column, narrower than it would be shrunk as far as it may be.
    private static func expectWhole(_ frame: CGRect, _ text: String, _ look: Look) {
        let smallest = idealWidth(text, look) * TimetableHeaderRow.minimumScale
        #expect(frame.width >= smallest - 0.5, "\(text) is cut off at \(frame.width) pt, \(smallest) pt at the smallest")
    }

    @Test("W12 stands whole over the period numbers, centred left of Monday, and reads as the week", arguments: looks)
    func week(look: Look) async throws {
        try await withAccessibilityAutomation {
            let window = try Self.show(week: 12, look: look)
            defer { window.isHidden = true }
            let days = try await Self.frames(of: look, in: window)
            window.saveSnapshot(as: "class-table-week-\(look.testDescription)-\(Self.language)")

            #expect(exposedAccessibilityLabels(in: window) == [Self.spokenWeek] + Self.labels(of: look))
            let label = try #require(accessibilityElement(labeled: Self.spokenWeek, in: window)).accessibilityFrame
            let spacing = TimetableGridView.columnSpacing
            let mondayStart = days[0].midX - (days[1].midX - days[0].midX - spacing) / 2
            let column = (start: Self.padding, end: mondayStart - spacing)
            #expect(abs(label.midX - (column.start + column.end) / 2) < 0.5, "\(label) off the centre of \(column)")
            #expect(label.minX >= column.start - 0.5 && label.maxX <= column.end + 0.5, "\(label) outside \(column)")
            #expect(abs(label.midY - days[0].midY) < 0.5, "\(label) beside \(days[0])")
            Self.expectWhole(label, "W12", look)
            for (frame, text) in zip(days, Self.labels(of: look)) {
                Self.expectWhole(frame, text, look)
            }
            let scales = zip(days, Self.labels(of: look)).map { $0.width / Self.idealWidth($1, look) }
            #expect((scales.max() ?? 0) - (scales.min() ?? 0) < 0.03, "the weekday names shrink by \(scales)")
        }
    }

    @Test("with no week the corner stays empty and the weekdays keep their places", arguments: looks)
    func noWeek(look: Look) async throws {
        try await withAccessibilityAutomation {
            let withWeek = try Self.show(week: 12, look: look)
            let placed = try await Self.frames(of: look, in: withWeek)
            withWeek.isHidden = true
            let window = try Self.show(week: nil, look: look)
            defer { window.isHidden = true }
            let days = try await Self.frames(of: look, in: window)
            window.saveSnapshot(as: "class-table-no-week-\(look.testDescription)-\(Self.language)")

            #expect(exposedAccessibilityLabels(in: window) == Self.labels(of: look))
            #expect(days == placed)
        }
    }
}
#endif
