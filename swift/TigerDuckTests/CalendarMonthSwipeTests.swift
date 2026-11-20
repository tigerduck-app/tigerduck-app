import Foundation
import SwiftUI
import Testing
import TigerDuckCore
@testable import TigerDuck

@MainActor
struct CalendarMonthPageTests {
    static func month(_ year: Int, _ month: Int, day: Int = 1) -> Date {
        TaipeiTime.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    @Test("a month's page plus n is n months later", arguments: [-25, -13, -12, -1, 0, 1, 2, 11, 12, 14, 25])
    func turns(n: Int) {
        let start = Self.month(2026, 11, day: 20)
        let expected = TaipeiTime.calendar.date(byAdding: .month, value: n, to: Self.month(2026, 11))
        #expect(CalendarViewModel.month(atPage: CalendarViewModel.monthPage(of: start) + n) == expected)
    }

    @Test func aTurnCrossesTheYear() {
        let december = CalendarViewModel.monthPage(of: Self.month(2026, 12, day: 31))
        #expect(CalendarViewModel.month(atPage: december + 1) == Self.month(2027, 1))
        #expect(CalendarViewModel.month(atPage: december - 11) == Self.month(2026, 1))
        #expect(CalendarViewModel.month(atPage: december - 12) == Self.month(2025, 12))
    }

    @Test func theFirstMinutesOfAMonthInTaipeiAreOnItsPage() {
        let justAfterMidnight = TaipeiTime.calendar.date(from: DateComponents(year: 2026, month: 12, day: 1, minute: 30))!
        #expect(CalendarViewModel.monthPage(of: justAfterMidnight) == CalendarViewModel.monthPage(of: Self.month(2026, 12)))
    }

    @Test func thePagesRunFrom1900Through2099() {
        let last = CalendarViewModel.monthPageCount - 1
        #expect(CalendarViewModel.month(atPage: 0) == Self.month(1900, 1))
        #expect(CalendarViewModel.month(atPage: last) == Self.month(2099, 12))
        #expect(CalendarViewModel.monthPage(of: Self.month(1899, 12)) == 0)
        #expect(CalendarViewModel.monthPage(of: Self.month(2100, 1)) == last)
    }

    @Test func todayShowsTheCurrentMonth() {
        let model = CalendarViewModel()
        model.displayedMonth = Self.month(2030, 6)
        model.goToToday()
        let now = TaipeiTime.calendar.dateComponents([.year, .month], from: .now)
        #expect(CalendarViewModel.month(atPage: CalendarViewModel.monthPage(of: model.displayedMonth))
            == Self.month(now.year!, now.month!))
    }
}

#if os(iOS)
@MainActor
@Suite(.serialized)
struct CalendarMonthSwipeScreenTests {
    /// December 2026 takes five weeks and January 2027 six.
    static let december = CalendarMonthPageTests.month(2026, 12)
    static let january = CalendarMonthPageTests.month(2027, 1)
    static let selected = CalendarMonthPageTests.month(2026, 12, day: 10)
    static let looks = [ClubScreensTests.looks[0], ClubScreensTests.looks[2]]
    /// A day cell's 40 points and the grid's spacing.
    static let week = 40 + TigerDuckTheme.Spacing.sm

    final class Shown {
        var months: [Date] = []
    }

    struct Page: View {
        let viewModel: CalendarViewModel
        let shown: Shown

        var body: some View {
            ScrollView {
                VStack(spacing: TigerDuckTheme.Spacing.lg) {
                    MonthCalendarView(viewModel: viewModel)
                    Divider()
                    Color.clear.frame(height: 1_500)
                }
            }
            .background(Color.backgroundPrimary)
            .onChange(of: viewModel.displayedMonth) { _, month in shown.months.append(month) }
        }
    }

    @MainActor struct Screen {
        let window: UIWindow
        let model: CalendarViewModel
        let pager: UIScrollView
        let shown: Shown

        var grid: CGRect { pager.convert(pager.bounds, to: window) }

        func rests(on month: Date) -> Bool {
            let offset = CGFloat(CalendarViewModel.monthPage(of: month)) * pager.bounds.width
            return !pager.isDragging && !pager.isDecelerating && abs(pager.contentOffset.x - offset) < 0.5
                && model.displayedMonth == month && shows(CalendarMonthSwipeScreenTests.title(of: month))
        }

        var state: String {
            return "page \(pager.contentOffset.x / pager.bounds.width) content \(pager.contentSize.width / pager.bounds.width) dragging \(pager.isDragging) decelerating \(pager.isDecelerating) month \(model.displayedMonth) height \(pager.bounds.height)"
        }

        func settle(on month: Date, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            try await waitUntil(timeout: .seconds(15), { rests(on: month) }, sourceLocation: sourceLocation)
            #expect(rests(on: month), "\(state)", sourceLocation: sourceLocation)
        }

        func shows(_ text: String) -> Bool {
            exposedAccessibilityTexts(in: window).contains(text)
        }

        func element(on day: Date) -> NSObject? {
            let date = day.formatted(Date.FormatStyle(
                date: .complete, time: .omitted, calendar: TaipeiTime.calendar, timeZone: TaipeiTime.timeZone
            ))
            return exposedAccessibilityElements(in: window).first { $0.accessibilityLabel?.hasPrefix(date) == true }
        }

        func swipe(_ fraction: CGFloat, over duration: Duration = .milliseconds(250)) async throws {
            window.makeKeyAndVisible()
            let travel = grid.width * fraction
            try await fingerDrag(
                from: CGPoint(x: grid.midX + travel / 2, y: grid.midY),
                to: CGPoint(x: grid.midX - travel / 2, y: grid.midY),
                over: duration, in: window
            )
        }

        func tap(_ element: NSObject) async throws {
            window.makeKeyAndVisible()
            try await fingerTap(at: window.convert(element.accessibilityActivationPoint, from: window.screen.coordinateSpace), in: window)
        }
    }

    static func title(of month: Date) -> String {
        var style = Date.FormatStyle.dateTime.year().month(.wide)
        style.timeZone = TaipeiTime.timeZone
        return month.formatted(style)
    }

    /// On iOS 26.5 a new window's first touch can go nowhere, so a tap on the empty page below the
    /// grid takes it.
    static func show(on month: Date, look: ClubScreensTests.Look = looks[0]) async throws -> Screen {
        let model = CalendarViewModel()
        model.displayedMonth = month
        model.selectedDate = selected
        let shown = Shown()
        let window = try ClubScreensTests.show(Page(viewModel: model, shown: shown), look: look, height: 812)
        let pager = { window.descendants(ofType: UIScrollView.self).first { $0.contentSize.width > 2 * $0.bounds.width } }
        try await waitUntil { pager() != nil }
        let screen = Screen(window: window, model: model, pager: try #require(pager()), shown: shown)
        #expect(screen.pager.contentSize.width == CGFloat(CalendarViewModel.monthPageCount) * screen.pager.bounds.width)
        try await screen.settle(on: month)
        #expect(shown.months.isEmpty, "the grid opens on its month without showing another first: \(shown.months)")
        try await fingerTap(at: CGPoint(x: window.bounds.midX, y: window.bounds.maxY - 20), in: window)
        return screen
    }

    @Test("the grid follows a swipe each way and a short drag snaps back, its height that of the taller month",
          arguments: looks)
    func swipes(look: ClubScreensTests.Look) async throws {
        try await withAccessibilityAutomation {
            let screen = try await Self.show(on: Self.december, look: look)
            defer { screen.window.isHidden = true }
            let fiveWeeks = screen.pager.bounds.height
            let sixWeeks = fiveWeeks + Self.week
            let isTall = { abs(screen.pager.bounds.height - sixWeeks) < 0.5 }
            let isShort = { abs(screen.pager.bounds.height - fiveWeeks) < 0.5 }
            let name = "calendar-month-swipe-\(look.testDescription)"
            screen.window.saveSnapshot(as: "\(name)-december")

            let grid = screen.grid
            let start = CGPoint(x: grid.midX + 120, y: grid.midY)
            let middle = CGPoint(x: grid.midX - 60, y: grid.midY)
            let end = CGPoint(x: grid.midX - 120, y: grid.midY)
            let finger = try Finger(in: screen.window)
            screen.window.makeKeyAndVisible()
            try finger.down(at: start)
            try await finger.slide(from: start, to: middle)
            try await waitUntil { isTall() }
            screen.window.saveSnapshot(as: "\(name)-mid-swipe")
            try await finger.slide(from: middle, to: end)
            #expect(isTall(), "the height holds through the rest of the swipe")
            try finger.up(at: end)
            try await screen.settle(on: Self.january)
            #expect(isTall())
            #expect(screen.model.selectedDate == Self.selected, "a swipe that starts on a day does not select it")
            screen.window.saveSnapshot(as: "\(name)-january")

            try await screen.swipe(-0.6)
            try await screen.settle(on: Self.december)
            try await waitUntil { isShort() }

            let offset = screen.pager.contentOffset.x
            let short = try Finger(in: screen.window)
            let from = CGPoint(x: grid.midX, y: grid.midY)
            let to = CGPoint(x: grid.midX - 40, y: grid.midY)
            screen.window.makeKeyAndVisible()
            try short.down(at: from)
            try await short.slide(from: from, to: to, steps: 20, pause: .milliseconds(30))
            try await waitUntil { screen.pager.contentOffset.x > offset + 10 }
            try short.up(at: to)
            try await screen.settle(on: Self.december)
            try await waitUntil { isShort() }
        }
    }

    @Test("the arrows turn the grid to the month a swipe shows")
    func arrows() async throws {
        try await withAccessibilityAutomation {
            let screen = try await Self.show(on: Self.december)
            defer { screen.window.isHidden = true }

            try await screen.swipe(0.6)
            try await screen.settle(on: Self.january)
            let swiped = screen.pager.contentOffset.x

            let previous = try #require(accessibilityElement(labeled: String(localized: "a11y_calendar_nav_prev"), in: screen.window))
            try await screen.tap(previous)
            try await screen.settle(on: Self.december)

            let next = try #require(accessibilityElement(labeled: String(localized: "a11y_calendar_nav_next"), in: screen.window))
            try await screen.tap(next)
            try await screen.settle(on: Self.january)
            #expect(abs(screen.pager.contentOffset.x - swiped) < 0.5)
        }
    }

    @Test("Today brings the grid back from a far month")
    func today() async throws {
        try await withAccessibilityAutomation {
            let screen = try await Self.show(on: CalendarMonthPageTests.month(2030, 6))
            defer { screen.window.isHidden = true }
            let now = TaipeiTime.calendar.dateComponents([.year, .month], from: .now)

            screen.model.goToToday()
            try await screen.settle(on: CalendarMonthPageTests.month(now.year!, now.month!))
        }
    }

    @Test("VoiceOver reaches the days of the month shown, a tap selects one, and a scroll that is not a drag turns the month")
    func voiceOver() async throws {
        try await withAccessibilityAutomation {
            let screen = try await Self.show(on: Self.december)
            defer { screen.window.isHidden = true }

            let days = (1...31).map { CalendarMonthPageTests.month(2026, 12, day: $0) }
            try await waitUntil { days.allSatisfy { screen.element(on: $0) != nil } }
            #expect(screen.element(on: Self.january) == nil, "the next month's page is hidden from VoiceOver")

            let day = try #require(screen.element(on: CalendarMonthPageTests.month(2026, 12, day: 24)))
            try await screen.tap(day)
            try await waitUntil { screen.model.selectedDate == CalendarMonthPageTests.month(2026, 12, day: 24) }

            // VoiceOver's three-finger swipe scrolls the pager by a page without a drag.
            screen.pager.setContentOffset(CGPoint(x: screen.pager.contentOffset.x + screen.pager.bounds.width, y: 0), animated: true)
            try await screen.settle(on: Self.january)
            #expect(screen.element(on: CalendarMonthPageTests.month(2027, 1, day: 31)) != nil)
        }
    }

    @Test("a vertical drag on the grid scrolls the page and keeps the month")
    func verticalDrag() async throws {
        try await withAccessibilityAutomation {
            let screen = try await Self.show(on: Self.december)
            defer { screen.window.isHidden = true }
            let page = try #require(screen.window.descendants(ofType: UIScrollView.self).first { $0 !== screen.pager })
            let grid = screen.grid

            screen.window.makeKeyAndVisible()
            try await fingerDrag(
                from: CGPoint(x: grid.midX, y: grid.maxY - 10), to: CGPoint(x: grid.midX, y: grid.maxY - 210),
                over: .milliseconds(400), in: screen.window
            )
            try await waitUntil { page.contentOffset.y > 100 && !page.isDecelerating }
            #expect(screen.rests(on: Self.december))
            #expect(screen.model.selectedDate == Self.selected)
        }
    }
}
#endif
