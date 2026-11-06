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

    /// The grid's own columns, drawn clear under the header, to show where its labels belong.
    private struct GridColumns: View {
        let look: Look
        private var periodColumn = TimetablePeriodColumn()

        init(look: Look) {
            self.look = look
        }

        var body: some View {
            TimetableGridView.columns(look.weekdays, periodWidth: periodColumn.width(drawsPeriodTiles: look.drawsPeriodTiles)) {
                column("grid period")
            } cell: { weekday in
                column("grid day \(weekday)")
            }
        }

        private func column(_ name: String) -> some View {
            Color.clear.frame(height: 1).accessibilityElement().accessibilityLabel(Text(verbatim: name))
        }
    }

    private static func gridColumns(of look: Look, in window: UIWindow) throws -> (period: CGRect, days: [CGRect]) {
        let frame = { (name: String) in try #require(accessibilityElement(labeled: name, in: window)).accessibilityFrame }
        return (try frame("grid period"), try look.weekdays.map { try frame("grid day \($0)") })
    }

    private static func headerLabels(in window: UIWindow) -> [String] {
        exposedAccessibilityLabels(in: window).filter { !$0.hasPrefix("grid ") }
    }

    private static func show(week: Int?, look: Look) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 200)
        window.overrideUserInterfaceStyle = look.style
        window.traitOverrides.preferredContentSizeCategory = look.textSize
        let header = VStack(spacing: 0) {
            TimetableHeaderRow(weekdays: look.weekdays, today: 3, week: week, drawsPeriodTiles: look.drawsPeriodTiles)
            GridColumns(look: look)
        }
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

    @Test("W12 stands whole and centred over the period numbers, no larger than the weekday names, and reads as the week", arguments: looks)
    func week(look: Look) async throws {
        try await withAccessibilityAutomation {
            let window = try Self.show(week: 12, look: look)
            defer { window.isHidden = true }
            let days = try await Self.frames(of: look, in: window)
            window.saveSnapshot(as: "class-table-week-\(look.testDescription)-\(Self.language)")

            #expect(Self.headerLabels(in: window) == [Self.spokenWeek] + Self.labels(of: look))
            let label = try #require(accessibilityElement(labeled: Self.spokenWeek, in: window)).accessibilityFrame
            let grid = try Self.gridColumns(of: look, in: window)
            #expect(abs(label.midX - grid.period.midX) < 0.5, "\(label) off the centre of \(grid.period)")
            #expect(label.minX >= grid.period.minX - 0.5 && label.maxX <= grid.period.maxX + 0.5, "\(label) outside \(grid.period)")
            for (name, column) in zip(days, grid.days) {
                #expect(abs(name.midX - column.midX) < 0.5, "\(name) off the centre of \(column)")
            }
            #expect(abs(label.midY - days[0].midY) < 0.5, "\(label) beside \(days[0])")
            Self.expectWhole(label, "W12", look)
            for (frame, text) in zip(days, Self.labels(of: look)) {
                Self.expectWhole(frame, text, look)
            }
            let scales = zip(days, Self.labels(of: look)).map { $0.width / Self.idealWidth($1, look) }
            #expect((scales.max() ?? 0) - (scales.min() ?? 0) < 0.03, "the weekday names shrink by \(scales)")
            let weekIdeal = Self.idealWidth("W12", look)
            let names = scales.min() ?? 1
            let expected = min(names, grid.period.width / weekIdeal, 1)
            #expect(abs(label.width / weekIdeal - expected) < 0.03, "W12 shrinks by \(label.width / weekIdeal), the names by \(names)")
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

            #expect(Self.headerLabels(in: window) == Self.labels(of: look))
            #expect(days == placed)
        }
    }
}
#endif
