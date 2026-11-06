import Defaults
import Foundation
import Testing
import TigerDuckCore
@testable import TigerDuck

@MainActor
struct ClassTableCalendarFileTests {
    private typealias File = ClassTableCalendarFile

    static func day(_ month: Int, _ day: Int, year: Int = 2026, hour: Int = 0, minute: Int = 0, second: Int = 0) -> Date {
        TaipeiTime.calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        )!
    }

    /// Monday 14 September 2026 to Friday 8 January 2027.
    static let days = QuietDayCalendar.Span(start: day(9, 14), end: day(1, 8, year: 2027))
    static let holidays = [
        QuietDayCalendar.Holiday(id: 1, span: .init(start: day(9, 30), end: day(9, 30))),
        QuietDayCalendar.Holiday(id: 2, span: .init(start: day(10, 7), end: day(10, 9))),
    ]
    static let term = SchoolCalendar.Term(
        code: "1151", days: days, quietDays: QuietDayCalendar(terms: [days], holidays: holidays, optedIn: [2])
    )

    static func structures() -> SDCourse {
        SDCourse(
            courseNo: "CS1001301", courseName: "資料結構", instructor: "王大明", classroom: "TR-313, IB-201",
            schedule: [3: ["6", "4", "3"]], semester: "1151",
            classroomMap: ["3-3": "TR-313", "3-4": "TR-313", "3-6": "IB-201"]
        )
    }

    static let now = day(11, 6, hour: 12)

    @Test("consecutive periods of a course on a day make one event, and a gap starts another")
    func meetingsMergeConsecutivePeriods() throws {
        let events = File.events(courses: [Self.structures()], term: Self.term, owner: nil)

        #expect(events.map(\.uid) == ["1151-CS1001301-3-3@tigerduck.app", "1151-CS1001301-3-6@tigerduck.app"])
        #expect(events.map(\.start) == [Self.day(9, 16, hour: 10, minute: 20), Self.day(9, 16, hour: 13, minute: 20)])
        #expect(events.map(\.end) == [Self.day(9, 16, hour: 12, minute: 10), Self.day(9, 16, hour: 14, minute: 10)])
        #expect(events.map(\.location) == ["TR-313", "IB-201"])
        #expect(events.map(\.summary) == ["資料結構", "資料結構"])
        #expect(events.map(\.description) == ["王大明\nCS1001301", "王大明\nCS1001301"])
    }

    @Test("each meeting repeats weekly from its first day in the term to the term's last day, in Taipei time")
    func weeklyThroughTheTerm() throws {
        let text = File.text(of: File.events(courses: [Self.structures()], term: Self.term, owner: nil), in: Self.term, now: Self.now)
        let lines = text.components(separatedBy: "\r\n")

        #expect(lines.contains("DTSTART;TZID=Asia/Taipei:20260916T102000"))
        #expect(lines.contains("DTEND;TZID=Asia/Taipei:20260916T121000"))
        #expect(lines.filter { $0 == "RRULE:FREQ=WEEKLY;UNTIL=20270108T155959Z" }.count == 2)
        #expect(lines.filter { $0 == "DTSTAMP:20261106T040000Z" }.count == 2)
        #expect(lines.contains("TZID:Asia/Taipei"))
        #expect(lines.contains("TZOFFSETTO:+0800"))
        #expect(Array(lines.prefix(2)) == ["BEGIN:VCALENDAR", "VERSION:2.0"])
        #expect(Array(lines.suffix(2)) == ["END:VCALENDAR", ""])
    }

    @Test("a meeting starts on the term's first such weekday, and a weekday the term never reaches has none")
    func firstMeetingDay() throws {
        let sunday = SDCourse(courseNo: "PE1010001", courseName: "Swimming", schedule: [7: ["1"], 1: ["2"]])
        let events = File.events(courses: [sunday], term: Self.term, owner: nil)
        #expect(events.map(\.start) == [Self.day(9, 14, hour: 9, minute: 10), Self.day(9, 20, hour: 8, minute: 10)])

        let short = QuietDayCalendar.Span(start: Self.day(7, 1), end: Self.day(7, 3))
        let summer = SchoolCalendar.Term(code: "114H", days: short, quietDays: QuietDayCalendar(terms: [short], holidays: []))
        #expect(File.events(courses: [sunday], term: summer, owner: nil).isEmpty)
    }

    @Test("a holiday takes its day's meetings out, except one the user keeps classes on")
    func holidaysExcludeTheirDays() throws {
        let events = File.events(courses: [Self.structures()], term: Self.term, owner: nil)
        let lines = File.text(of: events, in: Self.term, now: Self.now).components(separatedBy: "\r\n")
        #expect(lines.filter { $0.hasPrefix("EXDATE") } == [
            "EXDATE;TZID=Asia/Taipei:20260930T102000", "EXDATE;TZID=Asia/Taipei:20260930T132000",
        ])
    }

    @Test("a series begins at its first meeting a holiday leaves, under the same uid and end")
    func aHolidayOnTheFirstDayMovesTheStart() throws {
        let firstWednesday = QuietDayCalendar.Holiday(id: 3, span: .init(start: Self.day(9, 16), end: Self.day(9, 16)))
        let term = SchoolCalendar.Term(
            code: "1151", days: Self.days,
            quietDays: QuietDayCalendar(terms: [Self.days], holidays: Self.holidays + [firstWednesday], optedIn: [2])
        )
        let events = File.events(courses: [Self.structures()], term: term, owner: nil)

        #expect(events.map(\.uid) == ["1151-CS1001301-3-3@tigerduck.app", "1151-CS1001301-3-6@tigerduck.app"])
        #expect(events.map(\.start) == [Self.day(9, 23, hour: 10, minute: 20), Self.day(9, 23, hour: 13, minute: 20)])
        #expect(events.map(\.end) == [Self.day(9, 23, hour: 12, minute: 10), Self.day(9, 23, hour: 14, minute: 10)])
        let lines = File.text(of: events, in: term, now: Self.now).components(separatedBy: "\r\n")
        #expect(!lines.contains { $0.contains("20260916T") })
        #expect(lines.filter { $0 == "RRULE:FREQ=WEEKLY;UNTIL=20270108T155959Z" }.count == 2)
        #expect(lines.filter { $0.hasPrefix("EXDATE") } == [
            "EXDATE;TZID=Asia/Taipei:20260930T102000", "EXDATE;TZID=Asia/Taipei:20260930T132000",
        ])

        let week = QuietDayCalendar.Span(start: Self.day(9, 14), end: Self.day(9, 18))
        let closed = SchoolCalendar.Term(code: "1151", days: week, quietDays: QuietDayCalendar(terms: [week], holidays: [firstWednesday]))
        #expect(File.events(courses: [Self.structures()], term: closed, owner: nil).isEmpty)
    }

    @Test("the menu's check finds a timed period on a weekday column without building the events")
    func timedMeetingCheck() {
        let untimed = [
            SDCourse(courseNo: "GE1100001", courseName: "Thesis"),
            SDCourse(courseNo: "GE1100002", courseName: "Practicum", schedule: [2: ["E"]]),
            SDCourse(courseNo: "GE1100003", courseName: "Fieldwork", schedule: [0: ["1"], 8: ["2"]]),
        ]
        #expect(!File.hasTimedMeeting(in: []))
        #expect(!File.hasTimedMeeting(in: untimed))
        #expect(File.hasTimedMeeting(in: untimed + [Self.structures()]))
    }

    @Test("courses with no timed period on a weekday are left out")
    func untimedCoursesLeftOut() {
        let courses = [
            SDCourse(courseNo: "GE1100001", courseName: "Thesis"),
            SDCourse(courseNo: "GE1100002", courseName: "Practicum", schedule: [2: ["E"]]),
            SDCourse(courseNo: "GE1100003", courseName: "Fieldwork", schedule: [0: ["1"], 8: ["2"]]),
            Self.structures(),
        ]
        #expect(File.events(courses: courses, term: Self.term, owner: nil).map(\.summary) == ["資料結構", "資料結構"])
        #expect(File.events(courses: [], term: Self.term, owner: nil).isEmpty)
    }

    @Test("someone else's table gets uids of its own, so a calendar holding both keeps both")
    func anotherStudentsUIDs() {
        let own = File.events(courses: [Self.structures()], term: Self.term, owner: nil)
        let ming = File.events(courses: [Self.structures()], term: Self.term, owner: "5F0B6B1E")

        #expect(ming.map(\.uid) == ["1151-CS1001301-3-3-5F0B6B1E@tigerduck.app", "1151-CS1001301-3-6-5F0B6B1E@tigerduck.app"])
        #expect(Set(own.map(\.uid)).isDisjoint(with: ming.map(\.uid)))
    }

    @Test("text is escaped, control characters dropped, and lines folded at 75 octets without splitting a character")
    func escapingAndFolding() throws {
        let name = "Seminar; Ethics, Law \\ Society\r\nPart\t2\u{7}"
        let long = String(repeating: "資訊安全與密碼學", count: 6)
        let seminar = SDCourse(courseNo: "CS4001301", courseName: name, instructor: "Lin, Mei", schedule: [1: ["A"]])
        let crypto = SDCourse(courseNo: "CS4002301", courseName: long, schedule: [2: ["B"]])
        let text = File.text(of: File.events(courses: [seminar, crypto], term: Self.term, owner: nil), in: Self.term, now: Self.now)

        #expect(text.contains("SUMMARY:Seminar\\; Ethics\\, Law \\\\ Society\\nPart\t2\r\n"))
        #expect(text.contains("DESCRIPTION:Lin\\, Mei\\nCS4001301\r\n"))
        let rows = text.components(separatedBy: "\r\n")
        #expect(rows.allSatisfy { $0.utf8.count <= 75 })
        #expect(rows.filter { $0.hasPrefix(" ") }.count == 2)
        #expect(!text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))

        let read = CalendarService.parseICS(text)
        #expect(read.map(\.title) == ["Seminar; Ethics, Law \\ Society\nPart\t2", long])
        #expect(read.map(\.date) == [Self.day(9, 14, hour: 18, minute: 25), Self.day(9, 15, hour: 19, minute: 20)])
    }

    @Test("folding breaks only past 75 octets and starts each continuation with a space")
    func foldingWidths() {
        let exact = String(repeating: "a", count: 75)
        #expect(ICSFormat.folded(exact) == exact)
        #expect(ICSFormat.folded(exact + "b") == exact + "\r\n b")
        let wide = String(repeating: "表", count: 26)
        #expect(ICSFormat.folded(wide) == String(repeating: "表", count: 25) + "\r\n 表")
    }

    @Test("a term the academic calendar does not have gives no dates; the user's holiday choices hold only on their own table")
    func termFromTheAcademicCalendar() throws {
        let calendar = AcademicCalendar(
            revision: 1,
            terms: [SemesterTerm(code: "1151", start: Self.day(9, 14), end: Self.day(1, 8, year: 2027))],
            holidays: [Holiday(id: 2, nameZh: "校慶補假", nameEn: "Anniversary", start: Self.day(10, 7), end: Self.day(10, 9))]
        )
        #expect(SchoolCalendar.term("1142", ownTable: true, calendar: calendar, optedIn: [2]) == nil)

        let own = try #require(SchoolCalendar.term("1151", ownTable: true, calendar: calendar, optedIn: [2]))
        let ming = try #require(SchoolCalendar.term("1151", ownTable: false, calendar: calendar, optedIn: [2]))
        #expect(own.code == "1151")
        #expect(own.days == Self.days)
        #expect(own.quietDays.isClassDay(Self.day(10, 7)))
        #expect(!ming.quietDays.isClassDay(Self.day(10, 7)))
        #expect(ming.quietDays.isClassDay(Self.day(10, 6)))
    }
}

#if os(iOS)
@MainActor
@Suite(.serialized)
struct ClassTableCalendarTableTests {
    private final class Folder {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClassTableCalendarTableTests-\(UUID().uuidString)", isDirectory: true)
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    @Test("the clubs drawn on the grid stay out of the file")
    func clubsLeftOut() async throws {
        try await withExclusiveRealDefaults {
            let stores = try ClubMock.stores(dates: ClassTableClubLayoutTests.dates)
            defer { ClubMock.reset(stores) }
            let model = ClassTableClubLayoutTests.model(stores)
            model.courses = ClubMock.tableCourses(semester: "1151")
            model.grid.showClubs(on: ClassTableClubLayoutTests.dates)
            #expect(!model.grid.clubs.isEmpty)

            let events = ClassTableCalendarFile.events(of: model, in: ClassTableCalendarFileTests.term)

            #expect(events.map(\.summary).sorted() == ClubMock.courses.map(\.no).sorted())
            let clubText = ClubMock.activities.flatMap { [$0.name, $0.location] }
            #expect(!events.contains { clubText.contains($0.summary) || clubText.contains($0.location) })
        }
    }

    @Test("someone else's table gives their courses, under uids of their own")
    func anotherStudentsTable() throws {
        let folder = Folder()
        let people = ImportedClassTableStore(fileURL: folder.url.appending(path: "imported.json"), signedInStudentId: { "B11300000" })
        let model = ClassTableViewModel(
            courses: CourseStore(folders: CacheFolders(root: folder.url.appending(path: "courses"))), importedTables: people
        )
        let calculus = SDCourse(courseNo: "MA1010001", courseName: "Calculus", schedule: [2: ["1", "2"]], semester: "1151")
        let ming = try #require(people.add(
            ClassTableShareCode(format: .tigerDuck, studentId: "B11300001", sharedAt: nil, terms: [
                ClassTableShareCode.Term(semester: "1151", courseNos: ["MA1010001"]),
            ]),
            nickname: "Ming", courses: ["1151": [calculus]], for: testSignIn
        ))
        people.show(ming.id)
        model.showShownTable()

        let events = ClassTableCalendarFile.events(of: model, in: ClassTableCalendarFileTests.term)

        #expect(events.map(\.summary) == ["Calculus"])
        #expect(events.map(\.uid) == ["1151-MA1010001-2-1-\(ming.id.uuidString)@tigerduck.app"])
    }
}
#endif
