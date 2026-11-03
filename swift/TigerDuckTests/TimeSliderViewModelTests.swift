import Defaults
import Testing
import Foundation
import TigerDuckCore
@testable import TigerDuck

/// On the main actor, like `TimeSliderViewModel`, whose init prepares a `UIFeedbackGenerator`
/// and can crash the test host off the main thread. The Swift 5 language mode does not flag a
/// test that builds the model off the main actor.
@MainActor
struct TimeSliderViewModelTests {

    @Test func dateFromTimeString_parsesCorrectly() {
        let ref = TaipeiTime.calendar.startOfDay(for: AppClock.now())
        let date = CourseTimeSlot.dateFromTimeString("10:20", on: ref)!
        let comps = TaipeiTime.calendar.dateComponents([.hour, .minute], from: date)
        #expect(comps.hour == 10)
        #expect(comps.minute == 20)
    }

    @Test func dateFromTimeString_invalidReturnsNil() {
        let ref = AppClock.now()
        #expect(CourseTimeSlot.dateFromTimeString("invalid", on: ref) == nil)
        #expect(CourseTimeSlot.dateFromTimeString("", on: ref) == nil)
    }

    @Test func aClassIsOverAtItsEnd() throws {
        let allDays = Dictionary(uniqueKeysWithValues: (1...7).map { ($0, ["3"]) })
        let viewModel = TimeSliderViewModel()
        viewModel.configure(courses: [SDCourse(courseNo: "TEST100", courseName: "Test", schedule: allDays)])
        let slot = try #require(viewModel.items.first)

        #expect(viewModel.state(at: slot.start) == .inClass([slot]))
        #expect(viewModel.state(at: slot.end) != .inClass([slot]))
    }

    @Test func holidaySlots_areLeftOffTheTimeline() {
        let allDays = Dictionary(uniqueKeysWithValues: (1...7).map { ($0, ["3", "4"]) })
        let course = SDCourse(courseNo: "TEST100", courseName: "Test", schedule: allDays)
        let today = AcademicCalendar.startOfDay(AppClock.now())
        let onToday: (CourseTimeSlot) -> Bool = { AcademicCalendar.startOfDay($0.date) == today }

        let schoolDay = TimeSliderViewModel()
        schoolDay.configure(courses: [course])
        let holiday = TimeSliderViewModel(isQuietDay: { AcademicCalendar.startOfDay($0) == today })
        holiday.configure(courses: [course])

        #expect(schoolDay.courseSlots.contains(where: onToday))
        #expect(!holiday.courseSlots.contains(where: onToday))
        #expect(holiday.courseSlots.count == schoolDay.courseSlots.filter { !onToday($0) }.count)
    }

    @Test func quietDayChange_rebuildsTheTimeline() async throws {
        let allDays = Dictionary(uniqueKeysWithValues: (1...7).map { ($0, ["3", "4"]) })
        let course = SDCourse(courseNo: "TEST100", courseName: "Test", schedule: allDays)
        let today = AcademicCalendar.startOfDay(AppClock.now())
        let onToday: (CourseTimeSlot) -> Bool = { AcademicCalendar.startOfDay($0.date) == today }
        var todayIsQuiet = false
        let viewModel = TimeSliderViewModel(isQuietDay: {
            todayIsQuiet && AcademicCalendar.startOfDay($0) == today
        })
        viewModel.configure(courses: [course])
        #expect(viewModel.courseSlots.contains(where: onToday))

        todayIsQuiet = true
        NotificationCenter.default.post(name: AppConstants.holidayNotifyDidChange, object: nil)

        try await waitUntil { !viewModel.courseSlots.contains(where: onToday) }
    }

    @Test func skippedClass_isLeftOffThatDay() {
        let allDays = Dictionary(uniqueKeysWithValues: (1...7).map { ($0, ["3", "4"]) })
        let skipped = SDCourse(courseNo: "TEST100", courseName: "Skipped", schedule: allDays)
        let kept = SDCourse(courseNo: "TEST200", courseName: "Kept", schedule: allDays.mapValues { _ in ["6"] })
        let today = AcademicCalendar.startOfDay(AppClock.now())
        let onToday: (CourseTimeSlot) -> Bool = { AcademicCalendar.startOfDay($0.date) == today }
        skipped.toggleSkip(on: AppClock.now())

        let viewModel = TimeSliderViewModel()
        viewModel.configure(courses: [skipped, kept])

        #expect(viewModel.courseSlots.filter(onToday).map(\.courseKey) == ["TEST200"])
        #expect(viewModel.courseSlots.contains { $0.courseKey == "TEST100" && !onToday($0) })
    }

    @Test func skipToggle_rebuildsTheTimeline() async throws {
        let allDays = Dictionary(uniqueKeysWithValues: (1...7).map { ($0, ["3", "4"]) })
        let course = SDCourse(courseNo: "TEST100", courseName: "Test", schedule: allDays)
        let today = AcademicCalendar.startOfDay(AppClock.now())
        let onToday: (CourseTimeSlot) -> Bool = { AcademicCalendar.startOfDay($0.date) == today }
        let viewModel = TimeSliderViewModel()
        viewModel.configure(courses: [course])
        #expect(viewModel.courseSlots.contains(where: onToday))

        course.toggleSkip(on: AppClock.now())

        try await waitUntil { !viewModel.courseSlots.contains(where: onToday) }
    }

    @Test func homeSlider_leavesOffDaysOutsideTheTerm() throws {
        let allDays = Dictionary(uniqueKeysWithValues: (1...7).map { ($0, ["3", "4"]) })
        let course = SDCourse(courseNo: "TEST100", courseName: "Test", schedule: allDays)
        let today = AcademicCalendar.startOfDay(AppClock.now())
        let weekAgo = try #require(AcademicCalendar.calendar.date(byAdding: .day, value: -7, to: today))
        let term = SemesterTerm(code: "1151", start: weekAgo, end: today)
        let store = try calendarStore(holding: AcademicCalendar(revision: 1, terms: [term], holidays: []))

        let viewModel = TimeSliderViewModel(isQuietDay: { !store.isClassDay($0) })
        viewModel.configure(courses: [course])

        let days = Set(viewModel.courseSlots.map { AcademicCalendar.startOfDay($0.date) })
        #expect(days.count == 8)
        #expect(days.allSatisfy(term.contains))
    }

    @Test func xOffset_returnsZeroWithNoCourses() {
        let vm = TimeSliderViewModel(clubs: Self.noClubs())
        vm.configure(courses: [])

        let calendar = TaipeiTime.calendar
        let today = calendar.startOfDay(for: AppClock.now())
        let now = calendar.date(byAdding: .hour, value: 10, to: today)!
        vm.selectedTime = now

        let future = calendar.date(byAdding: .hour, value: 11, to: today)!
        #expect(vm.xOffset(for: future) == 0)

        let past = calendar.date(byAdding: .minute, value: -30, to: now)!
        #expect(vm.xOffset(for: past) == 0)
    }

    @Test func xOffset_returnsCorrectPixels() {
        let vm = TimeSliderViewModel()
        let calendar = TaipeiTime.calendar
        let today = calendar.startOfDay(for: AppClock.now())

        let allDays = Dictionary(uniqueKeysWithValues: (1...7).map { ($0, ["3", "4"]) })
        let course = SDCourse(courseNo: "TEST100", courseName: "Test", schedule: allDays)
        vm.configure(courses: [course])

        let selectedTime = calendar.date(byAdding: DateComponents(hour: 11), to: today)!
        vm.selectedTime = selectedTime

        let ppm = TimeSliderMetrics.pointsPerMinute

        let future = calendar.date(byAdding: .minute, value: 15, to: selectedTime)!
        let offset = vm.xOffset(for: future)
        #expect(abs(offset - 15.0 * ppm) < 0.01)

        let past = calendar.date(byAdding: .minute, value: -15, to: selectedTime)!
        let pastOffset = vm.xOffset(for: past)
        #expect(abs(pastOffset - (-15.0 * ppm)) < 0.01)
    }

    @Test func courseState_inClass() {
        let vm = TimeSliderViewModel()
        let calendar = TaipeiTime.calendar
        let today = calendar.startOfDay(for: AppClock.now())
        let slot = makeMockSlot(
            courseNo: "MATH101",
            start: calendar.date(byAdding: .hour, value: 10, to: today)!,
            end: calendar.date(byAdding: .hour, value: 12, to: today)!
        )
        vm.items = [.course(slot)]

        let during = calendar.date(byAdding: .hour, value: 11, to: today)!
        let state = vm.state(at: during)
        if case .inClass(let slots) = state {
            #expect(slots.compactMap(\.course).map(\.courseKey) == ["MATH101"])
        } else {
            Issue.record("Expected .inClass, got \(state)")
        }
    }

    @Test func courseState_inClass_keepsEveryOverlappingCourse() {
        let vm = TimeSliderViewModel()
        let calendar = TaipeiTime.calendar
        let today = calendar.startOfDay(for: AppClock.now())
        let earlier = makeMockSlot(
            courseNo: "MATH101",
            start: calendar.date(byAdding: .hour, value: 10, to: today)!,
            end: calendar.date(byAdding: .hour, value: 12, to: today)!
        )
        let later = makeMockSlot(
            courseNo: "PHYS101",
            start: calendar.date(byAdding: .hour, value: 11, to: today)!,
            end: calendar.date(byAdding: .hour, value: 13, to: today)!
        )
        vm.items = [.course(earlier), .course(later)]

        let during = calendar.date(byAdding: .minute, value: 690, to: today)!
        guard case .inClass(let slots) = vm.state(at: during) else {
            Issue.record("Expected .inClass, got \(vm.state(at: during))")
            return
        }
        #expect(slots.compactMap(\.course).map(\.courseKey) == ["MATH101", "PHYS101"])
    }

    @Test func timelineResolver_inClass_ordersOverlapsAsGiven() {
        let calendar = TaipeiTime.calendar
        let today = calendar.startOfDay(for: AppClock.now())
        let earlier = makeMockSlot(
            courseNo: "MATH101",
            start: calendar.date(byAdding: .hour, value: 10, to: today)!,
            end: calendar.date(byAdding: .hour, value: 12, to: today)!
        )
        let later = makeMockSlot(
            courseNo: "PHYS101",
            start: calendar.date(byAdding: .hour, value: 11, to: today)!,
            end: calendar.date(byAdding: .hour, value: 13, to: today)!
        )
        let during = calendar.date(byAdding: .minute, value: 690, to: today)!

        let state = CourseTimelineResolver().state(at: during, in: [earlier, later])
        guard case .inClass(let slots) = state else {
            Issue.record("Expected .inClass, got \(state)")
            return
        }
        #expect(slots.map(\.courseKey) == ["MATH101", "PHYS101"])
        #expect(slots.first?.courseKey == "MATH101")
    }

    @Test func courseState_beforeFirst() {
        let vm = TimeSliderViewModel()
        let calendar = TaipeiTime.calendar
        let today = calendar.startOfDay(for: AppClock.now())
        let slot = makeMockSlot(
            courseNo: "MATH101",
            start: calendar.date(byAdding: .hour, value: 10, to: today)!,
            end: calendar.date(byAdding: .hour, value: 12, to: today)!
        )
        vm.items = [.course(slot)]

        let before = calendar.date(byAdding: .hour, value: 9, to: today)!
        let state = vm.state(at: before)
        if case .beforeFirst(let next) = state {
            #expect(next.course?.courseKey == "MATH101")
        } else {
            Issue.record("Expected .beforeFirst, got \(state)")
        }
    }

    @Test func courseState_between() {
        let vm = TimeSliderViewModel()
        let calendar = TaipeiTime.calendar
        let today = calendar.startOfDay(for: AppClock.now())
        let slot1 = makeMockSlot(
            courseNo: "MATH101",
            start: calendar.date(byAdding: .hour, value: 8, to: today)!,
            end: calendar.date(byAdding: .hour, value: 10, to: today)!
        )
        let slot2 = makeMockSlot(
            courseNo: "PHYS201",
            start: calendar.date(byAdding: .hour, value: 13, to: today)!,
            end: calendar.date(byAdding: .hour, value: 15, to: today)!
        )
        vm.items = [.course(slot1), .course(slot2)]

        let gap = calendar.date(byAdding: .hour, value: 11, to: today)!
        let state = vm.state(at: gap)
        if case .between(let prev, let next) = state {
            #expect(prev?.course?.courseKey == "MATH101")
            #expect(next?.course?.courseKey == "PHYS201")
        } else {
            Issue.record("Expected .between, got \(state)")
        }
    }

    @Test func drag_advancesPastOverlappingCourses() {
        let vm = TimeSliderViewModel()
        let calendar = TaipeiTime.calendar
        let today = calendar.startOfDay(for: AppClock.now())

        let periods34 = Dictionary(uniqueKeysWithValues: (1...7).map { ($0, ["3", "4"]) })
        let periods45 = Dictionary(uniqueKeysWithValues: (1...7).map { ($0, ["4", "5"]) })
        vm.configure(courses: [
            SDCourse(courseNo: "CLASH1", courseName: "A", schedule: periods34),
            SDCourse(courseNo: "CLASH2", courseName: "B", schedule: periods34),
            SDCourse(courseNo: "CLASH3", courseName: "C", schedule: periods45),
        ])
        vm.selectedTime = calendar.date(byAdding: DateComponents(hour: 11), to: today)!

        var previousX = vm.xOffset(for: vm.selectedTime)
        for minutes in stride(from: 5, through: 240, by: 5) {
            let t = calendar.date(byAdding: .minute, value: minutes, to: vm.selectedTime)!
            let x = vm.xOffset(for: t)
            #expect(x > previousX, "x must keep growing at +\(minutes) min")
            previousX = x
        }

        var previous = vm.selectedTime
        for _ in 0..<60 {
            vm.onDragChanged(dx: -20, invertDirection: false)
            #expect(vm.selectedTime > previous)
            previous = vm.selectedTime
        }
        let blockEnd = calendar.date(byAdding: DateComponents(hour: 13, minute: 10), to: today)!
        #expect(vm.selectedTime > blockEnd)
        vm.isUserDragging = false
    }

    @Test func clashingSlotsStackInLanes() {
        let calendar = TaipeiTime.calendar
        let today = calendar.startOfDay(for: AppClock.now())
        func at(_ hour: Int) -> Date { calendar.date(byAdding: .hour, value: hour, to: today)! }
        let vm = TimeSliderViewModel()

        vm.items = [
            makeMockSlot(courseNo: "A", start: at(9), end: at(11)),
            makeMockSlot(courseNo: "B", start: at(10), end: at(12)),
            makeMockSlot(courseNo: "C", start: at(11), end: at(13)),
            makeMockSlot(courseNo: "D", start: at(14), end: at(15)),
        ].map(TimeSliderItem.course)

        #expect(vm.slotLanes["A"] == TimeSliderLane(lane: 0, count: 2))
        #expect(vm.slotLanes["B"] == TimeSliderLane(lane: 1, count: 2))
        #expect(vm.slotLanes["C"] == TimeSliderLane(lane: 0, count: 2))
        #expect(vm.slotLanes["D"] == nil)
    }

    @Test func backToBackSlotsKeepTheFullHeight() {
        let calendar = TaipeiTime.calendar
        let today = calendar.startOfDay(for: AppClock.now())
        func at(_ hour: Int) -> Date { calendar.date(byAdding: .hour, value: hour, to: today)! }

        let lanes = TimeSliderLayout.lanes(for: [
            makeMockSlot(courseNo: "A", start: at(9), end: at(10)),
            makeMockSlot(courseNo: "B", start: at(10), end: at(11)),
        ].map(TimeSliderItem.course))

        #expect(lanes.isEmpty)
    }

    static let week = (1...7).map { ClassTableViewModel.nextDate(onWeekday: $0, from: AppClock.now()) }

    /// A feed with no activity, so no club the simulator has stored reaches the test.
    static func noClubs() -> ClubActivities {
        ClubActivities(files: ClubFiles(folders: CacheFolders(
            root: FileManager.default.temporaryDirectory.appending(path: "NoClubs-\(UUID().uuidString)")
        )))
    }

    /// The pieces of Monday's activities. In `ClubMock` Monday's GE3105701 meets 18:25-19:15, and
    /// two clubs meet from 19:00, the higher ranked to 21:00 and the other to 21:30.
    static func mondayClubs(_ viewModel: TimeSliderViewModel) -> [String] {
        viewModel.items.compactMap { item in
            guard let club = item.club, TaipeiTime.calendar.isDate(item.date, inSameDayAs: week[0]) else { return nil }
            return "\(club.id) \(item.start.timeString)-\(item.end.timeString)"
        }
    }

    static func shown(at time: String, in viewModel: TimeSliderViewModel) -> [String] {
        guard case .inClass(let items) = viewModel.state(at: week[0].addingTimeInterval(TimeInterval(ClubMock.minutes(time) * 60)))
        else { return [] }
        return items.map { $0.course?.courseKey ?? "club \($0.club?.id ?? 0)" }
    }

    @Test("a club shows where no class and no higher-ranked club sits, and whole on a quiet day", arguments: [false, true])
    func clubsAroundClasses(quietMonday: Bool) async throws {
        try await withExclusiveRealDefaults {
            let stores = try ClubMock.stores(dates: Self.week)
            defer { ClubMock.reset(stores) }
            let monday = TaipeiTime.dayKey(for: Self.week[0])
            let viewModel = TimeSliderViewModel(
                isQuietDay: { quietMonday && TaipeiTime.dayKey(for: $0) == monday }, clubs: stores.feed
            )

            viewModel.configure(courses: ClubMock.tableCourses(semester: "1151"))

            #expect(Self.mondayClubs(viewModel) == (quietMonday
                ? ["1 19:00-21:00", "2 21:00-21:30"] : ["1 19:15-21:00", "2 21:00-21:30"]))
            #expect(Self.shown(at: "19:05", in: viewModel) == (quietMonday ? ["club 1"] : ["GE3105701"]))
            #expect(Self.shown(at: "19:30", in: viewModel) == ["club 1"])
            #expect(Self.shown(at: "21:10", in: viewModel) == ["club 2"])
        }
    }

    @Test("a change of subscriptions redraws the clubs")
    func subscriptionChangeRedrawsTheClubs() async throws {
        try await withExclusiveRealDefaults {
            let stores = try ClubMock.stores(dates: Self.week)
            defer { ClubMock.reset(stores) }
            let viewModel = TimeSliderViewModel(clubs: stores.feed)
            viewModel.configure(courses: ClubMock.tableCourses(semester: "1151"))
            #expect(Self.mondayClubs(viewModel) == ["1 19:15-21:00", "2 21:00-21:30"])

            stores.subscriptions.unsubscribe(101, for: testSignIn)

            try await waitUntil { Self.mondayClubs(viewModel) == ["2 19:15-21:30"] }
        }
    }

    @Test("a cancelled class still covers a club, as the track still draws it")
    func cancelledClassCoversAClub() {
        let day = TaipeiTime.calendar.startOfDay(for: AppClock.now())
        func at(_ time: String) -> Date { day.addingTimeInterval(TimeInterval(ClubMock.minutes(time) * 60)) }
        var slot = makeMockSlot(courseNo: "MATH101", start: at("19:00"), end: at("20:00"))
        slot.changes = [CourseChange(
            id: 1, courseNo: "MATH101", kind: .cancelled, periods: .everyPeriodThatDay,
            room: nil, startHHmm: nil, endHHmm: nil, noteZh: nil, noteEn: nil
        )]
        let club = ClubOccurrence(
            id: 9, clubID: 101, clubName: "資訊安全研究社", color: 0x3366CC, priority: 0, day: TaipeiTime.dayKey(for: day),
            start: ClubMock.minutes("18:30"), end: ClubMock.minutes("21:00"), location: "TR-412", kind: .meeting,
            name: "社課", content: ""
        )

        let items = TimeSliderItem.timeline(courses: [slot], clubs: [club], days: [day])

        #expect(items.map { "\($0.club == nil ? "class" : "club") \($0.start.timeString)-\($0.end.timeString)" }
            == ["club 18:30-19:00", "class 19:00-20:00", "club 20:00-21:00"])
    }

    private func calendarStore(holding calendar: AcademicCalendar) throws -> AcademicCalendarStore {
        let saved = Defaults[.academicCalendarCache]
        defer { Defaults[.academicCalendarCache] = saved }
        Defaults[.academicCalendarCache] = try JSONEncoder().encode(calendar)
        return AcademicCalendarStore()
    }

    private func makeMockSlot(courseNo: String, start: Date, end: Date) -> CourseTimeSlot {
        let course = SDCourse(
            courseNo: courseNo,
            courseName: courseNo,
            instructor: "Test",
            credits: 3,
            classroom: "101",
            enrolledCount: 30,
            maxCount: 50,
            schedule: [:]
        )
        return CourseTimeSlot(id: courseNo, course: course, start: start, end: end, date: start)
    }
}

extension TimeSliderItem {
    var course: CourseTimeSlot? { if case .course(let slot) = self { slot } else { nil } }
    var club: ClubOccurrence? { if case .club(let piece, _) = self { piece.occurrence } else { nil } }
}

extension TimeSliderViewModel {
    var courseSlots: [CourseTimeSlot] { items.compactMap(\.course) }
}
