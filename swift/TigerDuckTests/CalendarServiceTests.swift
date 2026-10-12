import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct CalendarServiceTests {
    private static func taipeiDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        AppConstants.taipeiCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// A hand-made school calendar: an all-day event, a three-day one with an escaped, folded
    /// summary, three timed ones (UTC, a TZID and local time) and one without a UID.
    private static let ics = """
    BEGIN:VCALENDAR
    VERSION:2.0
    BEGIN:VEVENT
    UID:opening@ntust
    DTSTART;VALUE=DATE:20250901
    DTEND;VALUE=DATE:20250902
    SUMMARY:開學
    END:VEVENT
    BEGIN:VEVENT
    UID:midterm@ntust
    DTSTART;VALUE=DATE:20251103
    DTEND;VALUE=DATE:20251106
    SUMMARY:期中考試週\\, 第一
     階段
    END:VEVENT
    BEGIN:VEVENT
    UID:briefing@ntust
    DTSTART:20250915T010000Z
    DTEND:20250915T020000Z
    SUMMARY:新生說明會
    END:VEVENT
    BEGIN:VEVENT
    UID:exchange@ntust
    DTSTART;TZID=Asia/Tokyo:20250920T100000
    SUMMARY:交換生座談
    END:VEVENT
    BEGIN:VEVENT
    UID:fair@ntust
    DTSTART:20251001T140000
    SUMMARY:就業博覽會
    END:VEVENT
    BEGIN:VEVENT
    DTSTART;VALUE=DATE:20251115
    SUMMARY:校慶
    END:VEVENT
    END:VCALENDAR
    """

    @Test("the school calendar parses into one row per day, in Taipei days")
    func parsesTheCalendar() {
        let events = CalendarService.parseICS(Self.ics)
        #expect(events.allSatisfy { $0.source == .school })

        let opening = events.filter { $0.title == "開學" }
        #expect(opening.map(\.eventId) == ["opening@ntust"])
        #expect(opening.map(\.date) == [Self.taipeiDate(2025, 9, 1)])

        let midterm = events.filter { $0.title == "期中考試週, 第一階段" }
        let days = [Self.taipeiDate(2025, 11, 3), Self.taipeiDate(2025, 11, 4), Self.taipeiDate(2025, 11, 5)]
        #expect(midterm.map(\.date) == days)
        #expect(midterm.map(\.eventId) == days.map { "midterm@ntust-\($0.timeIntervalSince1970)" })

        #expect(events.first { $0.eventId == "briefing@ntust" }?.date == Self.taipeiDate(2025, 9, 15, 9))
        #expect(events.first { $0.eventId == "exchange@ntust" }?.date == Self.taipeiDate(2025, 9, 20, 9))
        #expect(events.first { $0.eventId == "fair@ntust" }?.date == Self.taipeiDate(2025, 10, 1, 14))

        let anniversary = Self.taipeiDate(2025, 11, 15)
        #expect(events.first { $0.title == "校慶" }?.eventId == "school-校慶-\(anniversary.timeIntervalSince1970)")
        #expect(events.count == 8)
    }

    @Test("ICS dates are read in the Gregorian calendar whatever the device calendar")
    func formattersIgnoreTheDeviceCalendar() {
        for formatter in [CalendarService.icsDateOnly, CalendarService.icsDateTime, CalendarService.icsDateTimeZ] {
            #expect(formatter.calendar.identifier == .gregorian)
            #expect(formatter.locale.identifier == "en_US_POSIX")
        }
    }

    @Test("the academic year turns over on the first of August, Taipei time")
    func academicYear() {
        #expect(CalendarService.rocAcademicYear(at: Self.taipeiDate(2026, 7, 31, 23)) == 114)
        #expect(CalendarService.rocAcademicYear(at: Self.taipeiDate(2026, 8, 1)) == 115)
        #expect(CalendarService.rocAcademicYear(at: Self.taipeiDate(2027, 1, 15)) == 115)
        #expect(CalendarService.rocAcademicYear(at: Self.taipeiDate(2025, 12, 31, 23)) == 114)
    }

    // MARK: - Fetching

    private struct Answers {
        var ics: SettingsAPIStub.StubResponse?
        var icsYear = 115
    }

    /// Serves the link page and, when given, the ICS file from `SettingsAPIStub`.
    private func fetch(_ answers: Answers) async -> [SDCalendarEvent]? {
        let base = SettingsAPIStub.uniqueBaseURL()
        let pageURL = base.appendingPathComponent("calendar")
        let icsURL = base.appendingPathComponent("calendar-\(answers.icsYear).ics")
        let page = #"<ul><li><a href="\#(icsURL.absoluteString)"><span>\#(answers.icsYear)</span>學年度行事曆</a></li></ul>"#
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data(page.utf8)), for: pageURL)
        if let ics = answers.ics { SettingsAPIStub.enqueue(ics, for: icsURL) }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        return await CalendarService.fetchAndParseICS(
            session: URLSession(configuration: config), pageURL: pageURL, now: Self.taipeiDate(2026, 10, 12)
        )
    }

    @Test("this year's calendar is downloaded and parsed")
    func fetchesThisYear() async {
        let events = await fetch(Answers(ics: .init(statusCode: 200, body: Data(Self.ics.utf8))))
        #expect(events?.count == 8)
    }

    @Test("a failed download gives nothing to replace the kept events with")
    func failedDownloadsGiveNil() async {
        let failures: [Answers] = [
            Answers(ics: nil),
            Answers(ics: .init(statusCode: 404, body: Data("<html>Not Found</html>".utf8))),
            Answers(ics: .init(statusCode: 200, body: Data("<html>Service Unavailable</html>".utf8))),
            Answers(ics: .init(statusCode: 200, body: Data(Self.ics.utf8)), icsYear: 114),
        ]
        for answers in failures {
            #expect(await fetch(answers) == nil)
        }
    }
}
