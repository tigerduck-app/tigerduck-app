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

    @Test func theCalendarOpensOnAndReturnsToTheClocksDay() {
        let today = Self.month(2031, 3, day: 15)
        let model = CalendarViewModel(now: { today })
        #expect(model.selectedDate == today)
        #expect(model.displayedMonth == today)
        #expect(model.calendarDays == CalendarViewModel.buildCalendarDays(for: today))
        model.selectedDate = Self.month(2030, 6, day: 2)
        model.displayedMonth = Self.month(2030, 6)
        model.goToToday()
        #expect(model.selectedDate == today)
        #expect(model.displayedMonth == today)
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
    static let week = 40 + TigerDuckTheme.Spacing.sm

    final class Shown {
        var months: [Date] = []
    }

    final class Posts {
        var titles: [String] = []
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

    @Observable
    final class Stack {
        var path: [Int] = []
        var isShown = false
    }

    /// The calendar as More pushes it.
    struct Pushed: View {
        @Bindable var stack: Stack
        let page: Page

        var body: some View {
            NavigationStack(path: $stack.path) {
                Color.backgroundPrimary
                    .onAppear { stack.isShown = true }
                    .navigationDestination(for: Int.self) { _ in MoreFeatureDestination { page } }
            }
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
                && model.displayedMonth == month && shows(MonthCalendarView.title(of: month))
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

        var sundayHeading: CGRect? {
            let sunday = String(localized: "weekday_sun_short")
            return exposedAccessibilityElements(in: window).first { $0.accessibilityLabel == sunday }?.accessibilityFrame
        }

        /// UIKit gives VoiceOver this text to speak after an accessibility page scroll.
        var scrollStatus: String? {
            pager.perform(NSSelectorFromString("_accessibilityScrollStatus"))?.takeUnretainedValue() as? String
        }

        /// VoiceOver's three-finger swipe left reaches the scroll view as this accessibility action.
        func scrollLeftPageAsVoiceOverDoes() -> Bool {
            let action = NSSelectorFromString("accessibilityScrollLeftPage")
            typealias Perform = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(pager.method(for: action), to: Perform.self)(pager, action)
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

    static func pager(in window: UIWindow) -> UIScrollView? {
        window.descendants(ofType: UIScrollView.self).first { $0.contentSize.width > 2 * $0.bounds.width && $0.bounds.width == window.bounds.width }
    }

    /// On iOS 26.5 a new window's first touch can go nowhere, so a tap on the empty page below the
    /// grid takes it.
    static func show(on month: Date, look: ClubScreensTests.Look = looks[0]) async throws -> Screen {
        let model = CalendarViewModel()
        model.displayedMonth = month
        model.selectedDate = selected
        let shown = Shown()
        let window = try ClubScreensTests.show(Page(viewModel: model, shown: shown), look: look, height: 812)
        let pager = { Self.pager(in: window) }
        try await waitUntil { pager() != nil }
        let screen = Screen(window: window, model: model, pager: try #require(pager()), shown: shown)
        #expect(screen.pager.contentSize.width == CGFloat(CalendarViewModel.monthPageCount) * screen.pager.bounds.width)
        try await screen.settle(on: month)
        #expect(shown.months.isEmpty, "the grid opens on its month without showing another first: \(shown.months)")
        try await fingerTap(at: CGPoint(x: window.bounds.midX, y: window.bounds.maxY - 20), in: window)
        return screen
    }

    @Test("pushed as More pushes it, the grid opens on today's month")
    func pushed() async throws {
        try await withAccessibilityAutomation {
            let model = CalendarViewModel(now: { Self.december })
            let shown = Shown()
            let stack = Stack()
            let window = try ClubScreensTests.show(Pushed(stack: stack, page: Page(viewModel: model, shown: shown)), look: Self.looks[0])
            defer { window.isHidden = true }
            try await waitUntil { stack.isShown }
            stack.path.append(1)
            let pager = { Self.pager(in: window) }
            try await waitUntil { pager() != nil }
            let screen = Screen(window: window, model: model, pager: try #require(pager()), shown: shown)
            try await screen.settle(on: Self.december)
            #expect(shown.months.isEmpty, "the grid opens on its month without showing another first: \(shown.months)")
        }
    }

    @Test("a change of width, as on an iPad's rotation, keeps the grid on its month")
    func resized() async throws {
        try await withAccessibilityAutomation {
            let screen = try await Self.show(on: Self.december)
            defer { screen.window.isHidden = true }
            for width in [CGFloat(700), ClubScreensTests.width] {
                UIView.animate(withDuration: 0.3) { screen.window.frame.size.width = width }
                try await waitUntil { Self.pager(in: screen.window) != nil }
                let resized = Screen(window: screen.window, model: screen.model, pager: try #require(Self.pager(in: screen.window)), shown: screen.shown)
                try await resized.settle(on: Self.december)
            }
            #expect(screen.shown.months.isEmpty, "the grid keeps its month without showing another: \(screen.shown.months)")
        }
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
            let sunday = try #require(screen.sundayHeading)
            let start = CGPoint(x: grid.midX + 120, y: grid.midY)
            let middle = CGPoint(x: grid.midX - 60, y: grid.midY)
            let end = CGPoint(x: grid.midX - 120, y: grid.midY)
            let finger = try Finger(in: screen.window)
            screen.window.makeKeyAndVisible()
            try finger.down(at: start)
            try await finger.slide(from: start, to: middle)
            try await waitUntil { isTall() }
            screen.window.saveSnapshot(as: "\(name)-mid-swipe")
            #expect(screen.sundayHeading == sunday, "the weekday row stays still while the days move")
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
            let from = CGPoint(x: grid.midX, y: grid.midY)
            let to = CGPoint(x: grid.midX - 40, y: grid.midY)
            // On iOS 26.5, with other suites' windows on screen, a slow drag's touches sometimes never
            // reach the grid.
            var moved = false
            for _ in 0..<3 where !moved {
                let short = try Finger(in: screen.window)
                screen.window.makeKeyAndVisible()
                try short.down(at: from)
                try await short.slide(from: from, to: to, steps: 20, pause: .milliseconds(30))
                moved = try await PageMenuScreenTests.holds(within: .seconds(2)) { screen.pager.contentOffset.x > offset + 10 }
                try short.up(at: to)
            }
            #expect(moved, "the short drag moved the grid")
            try await screen.settle(on: Self.december)
            try await waitUntil { isShort() }
        }
    }

    @Test("the arrows turn the grid to the month a swipe shows, posting no page scroll")
    func arrows() async throws {
        try await withAccessibilityAutomation {
            let posts = Posts()
            let post = MonthCalendarView.postPageScrolled
            MonthCalendarView.postPageScrolled = { posts.titles.append($0) }
            defer { MonthCalendarView.postPageScrolled = post }
            let screen = try await Self.show(on: Self.december)
            defer { screen.window.isHidden = true }

            try await screen.swipe(0.6)
            try await screen.settle(on: Self.january)
            if #unavailable(iOS 26) {
                try await waitUntil { !posts.titles.isEmpty }
            }
            let swiped = screen.pager.contentOffset.x

            let previous = try #require(accessibilityElement(labeled: String(localized: "a11y_calendar_nav_prev"), in: screen.window))
            try await screen.tap(previous)
            try await screen.settle(on: Self.december)

            let next = try #require(accessibilityElement(labeled: String(localized: "a11y_calendar_nav_next"), in: screen.window))
            try await screen.tap(next)
            try await screen.settle(on: Self.january)
            #expect(abs(screen.pager.contentOffset.x - swiped) < 0.5)
            try await Task.sleep(for: MonthCalendarView.pageScrolledDelay * 3)
            if #available(iOS 26, *) {
                #expect(posts.titles.isEmpty)
            } else {
                #expect(posts.titles == [MonthCalendarView.title(of: Self.january)], "only the swipe posts")
            }
        }
    }

    @Test("an arrow or Today while a page scroll's month waits to be said drops it")
    func turnDuringTheWait() async throws {
        try await withAccessibilityAutomation {
            let posts = Posts()
            let (post, delay) = (MonthCalendarView.postPageScrolled, MonthCalendarView.pageScrolledDelay)
            MonthCalendarView.postPageScrolled = { posts.titles.append($0) }
            MonthCalendarView.pageScrolledDelay = .seconds(2)
            defer {
                MonthCalendarView.postPageScrolled = post
                MonthCalendarView.pageScrolledDelay = delay
            }
            let screen = try await Self.show(on: Self.december)
            defer { screen.window.isHidden = true }

            #expect(screen.scrollLeftPageAsVoiceOverDoes())
            try await screen.settle(on: Self.january)
            try await Task.sleep(for: .milliseconds(300))
            screen.model.displayedMonth = Self.december
            try await screen.settle(on: Self.december)
            try await Task.sleep(for: .seconds(3))
            #expect(posts.titles.isEmpty)
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

    @Test("VoiceOver reaches the days of the month shown, a tap selects one, and its page scroll turns the month and says it once")
    func voiceOver() async throws {
        try await withAccessibilityAutomation {
            let posts = Posts()
            let post = MonthCalendarView.postPageScrolled
            MonthCalendarView.postPageScrolled = { posts.titles.append($0) }
            defer { MonthCalendarView.postPageScrolled = post }
            let screen = try await Self.show(on: Self.december)
            defer { screen.window.isHidden = true }

            let days = (1...31).map { CalendarMonthPageTests.month(2026, 12, day: $0) }
            try await waitUntil { days.allSatisfy { screen.element(on: $0) != nil } }
            #expect(screen.element(on: Self.january) == nil, "the next month's page is hidden from VoiceOver")

            let day = try #require(screen.element(on: CalendarMonthPageTests.month(2026, 12, day: 24)))
            try await screen.tap(day)
            try await waitUntil { screen.model.selectedDate == CalendarMonthPageTests.month(2026, 12, day: 24) }

            #expect(screen.scrollLeftPageAsVoiceOverDoes())
            try await screen.settle(on: Self.january)
            #expect(screen.element(on: CalendarMonthPageTests.month(2027, 1, day: 31)) != nil)
            let january = MonthCalendarView.title(of: Self.january)
            if #available(iOS 26, *) {
                let status = screen.scrollStatus
                #expect(status == january)
                #expect(posts.titles.isEmpty, "the scroll status says the month, so nothing else does")
            } else {
                try await waitUntil { !posts.titles.isEmpty }
                try await Task.sleep(for: MonthCalendarView.pageScrolledDelay * 3)
                #expect(posts.titles == [january])
            }
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
