import Defaults
import Foundation
import os
import TigerDuckCore

nonisolated struct SemesterTerm: Codable, Equatable, Sendable {
    let code: String
    let start: Date
    let end: Date

    func contains(_ day: Date) -> Bool {
        QuietDayCalendar.Span(start: start, end: end).contains(day)
    }
}

nonisolated struct Holiday: Codable, Equatable, Sendable, Identifiable {
    let id: Int
    let nameZh: String
    let nameEn: String
    let start: Date
    let end: Date

    func contains(_ day: Date) -> Bool {
        QuietDayCalendar.Span(start: start, end: end).contains(day)
    }

    func name(for locale: Locale = .current) -> String {
        (locale.identifier.hasPrefix("zh") || locale.language.languageCode?.identifier == "zh")
            ? nameZh
            : nameEn
    }
}

nonisolated struct AcademicCalendar: Codable, Equatable, Sendable {
    let revision: Int
    let terms: [SemesterTerm]
    let holidays: [Holiday]

    static let empty = AcademicCalendar(revision: 0, terms: [], holidays: [])

    /// The class table reads this for every cell, so it decodes only when the stored data changes.
    static var cached: AcademicCalendar {
        let data = Defaults[.academicCalendarCache]
        guard !data.isEmpty else { return .empty }
        return lastDecoded.withLock { last in
            if let last, last.data == data { return last.calendar }
            let calendar = (try? JSONDecoder().decode(AcademicCalendar.self, from: data)) ?? .empty
            last = (data, calendar)
            return calendar
        }
    }

    private static let lastDecoded = OSAllocatedUnfairLock<(data: Data, calendar: AcademicCalendar)?>(initialState: nil)

    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TaipeiTime.timeZone
        return c
    }()

    static func startOfDay(_ date: Date) -> Date { calendar.startOfDay(for: date) }

    func currentTerm(on day: Date = Date()) -> SemesterTerm? {
        guard !terms.isEmpty else { return nil }
        let d = Self.startOfDay(day)
        let begun = terms.filter { $0.start <= d }
        return begun.max(by: { $0.start < $1.start })
            ?? terms.min(by: { $0.start < $1.start })
    }

    func quietDays(optedIn: Set<Int>) -> QuietDayCalendar {
        QuietDayCalendar(
            terms: terms.map { QuietDayCalendar.Span(start: $0.start, end: $0.end) },
            holidays: holidays.map { QuietDayCalendar.Holiday(id: $0.id, span: .init(start: $0.start, end: $0.end)) },
            optedIn: optedIn
        )
    }

    func isInSession(on day: Date = Date()) -> Bool {
        quietDays(optedIn: []).isInSession(day)
    }

    func holidays(on day: Date) -> [Holiday] {
        holidays.filter { $0.contains(day) }
    }

    func suppressesClasses(on day: Date, optedIn: Set<Int>) -> Bool {
        quietDays(optedIn: optedIn).suppressesClasses(on: day)
    }

    func isClassDay(_ day: Date, optedIn: Set<Int>) -> Bool {
        quietDays(optedIn: optedIn).isClassDay(day)
    }
}

nonisolated struct AcademicCalendarDTO: Decodable, Sendable {
    struct Semester: Decodable, Sendable {
        let code: String
        let start: String
        let end: String
    }

    struct HolidayRow: Decodable, Sendable {
        let id: Int
        let name_zh: String?
        let name_en: String?
        let start: String
        let end: String
    }

    let revision: Int
    let semesters: [Semester]?
    let holidays: [HolidayRow]?
}

nonisolated extension AcademicCalendar {
    init(dto: AcademicCalendarDTO) {
        let terms: [SemesterTerm] = (dto.semesters ?? []).compactMap { row in
            guard !row.code.isEmpty,
                  let start = AcademicCalendar.day(from: row.start),
                  let end = AcademicCalendar.day(from: row.end),
                  end >= start
            else { return nil }
            return SemesterTerm(code: row.code, start: start, end: end)
        }
        let holidays: [Holiday] = (dto.holidays ?? []).compactMap { row in
            guard let start = AcademicCalendar.day(from: row.start),
                  let end = AcademicCalendar.day(from: row.end),
                  end >= start
            else { return nil }
            let zh = row.name_zh?.isEmpty == false ? row.name_zh : nil
            let en = row.name_en?.isEmpty == false ? row.name_en : nil
            guard zh != nil || en != nil else { return nil }
            return Holiday(
                id: row.id,
                nameZh: zh ?? en!,
                nameEn: en ?? zh!,
                start: start,
                end: end
            )
        }
        self.init(revision: dto.revision, terms: terms, holidays: holidays)
    }

    static func day(from text: String) -> Date? {
        let parts = text.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let dayOfMonth = Int(parts[2])
        else { return nil }
        return calendar.date(
            from: DateComponents(year: year, month: month, day: dayOfMonth)
        )
    }
}
