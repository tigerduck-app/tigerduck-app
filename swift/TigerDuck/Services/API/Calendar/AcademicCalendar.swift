import Defaults
import Foundation

/// One published term, with the inclusive days classes run between.
nonisolated struct SemesterTerm: Codable, Equatable, Sendable {
    let code: String
    let start: Date
    let end: Date

    func contains(_ day: Date) -> Bool {
        let d = AcademicCalendar.startOfDay(day)
        return d >= start && d <= end
    }
}

/// A named range on which classes do not meet. Single-day: `start == end`.
nonisolated struct Holiday: Codable, Equatable, Sendable, Identifiable {
    let id: Int
    let nameZh: String
    let nameEn: String
    let start: Date
    let end: Date

    func contains(_ day: Date) -> Bool {
        let d = AcademicCalendar.startOfDay(day)
        return d >= start && d <= end
    }

    /// Chinese for any `zh-*` locale, English otherwise — matching how the
    /// backend authors the pair.
    func name(for locale: Locale = .current) -> String {
        (locale.identifier.hasPrefix("zh") || locale.language.languageCode?.identifier == "zh")
            ? nameZh
            : nameEn
    }
}

/// The school's calendar, as the app reasons about it.
///
/// A value type so the widget extension, the Live Activity coordinator and
/// the views can all hold the same answer without coordinating. Everything
/// that touches the network or disk lives in `AcademicCalendarStore`.
///
/// `empty` is the state before the first successful fetch, and every
/// predicate is written so that state behaves exactly as the app did before
/// this feature existed: nothing suppressed, term falls back to the caller's
/// own guess. Failing open matters more than failing safe — silencing every
/// class reminder because a server was unreachable is a far worse bug than
/// ringing once on a holiday.
nonisolated struct AcademicCalendar: Codable, Equatable, Sendable {
    let revision: Int
    let terms: [SemesterTerm]
    let holidays: [Holiday]

    static let empty = AcademicCalendar(revision: 0, terms: [], holidays: [])

    /// The cached calendar, readable from any isolation.
    ///
    /// `AcademicCalendarStore` is `@MainActor` because it owns the refresh
    /// task, but `CourseSelectionService.currentSemesterCode()` is
    /// `nonisolated` and is called from background work. Both read the same
    /// `Defaults` entry, so this is the same answer without hopping actors.
    ///
    /// That only holds because the type carries `nonisolated`: the target
    /// builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so without
    /// it every member here would be main-actor isolated and this would be
    /// an error under the Swift 6 language mode rather than the free read
    /// it is meant to be.
    static var cached: AcademicCalendar {
        let data = Defaults[.academicCalendarCache]
        guard !data.isEmpty else { return .empty }
        return (try? JSONDecoder().decode(AcademicCalendar.self, from: data)) ?? .empty
    }

    /// Taipei, always — every date in this calendar is a Taiwan school day,
    /// not an instant, so the device's own zone must not enter into it.
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei") ?? .current
        return c
    }()

    static func startOfDay(_ date: Date) -> Date { calendar.startOfDay(for: date) }

    /// The term whose timetable the app should be showing.
    ///
    /// The most recently *begun* term, not the one containing `day`: between
    /// terms there is no containing term, and the app has always kept showing
    /// the last timetable rather than emptying itself. Suppression is the
    /// holidays' job, so this stays deliberately permissive.
    func currentTerm(on day: Date = Date()) -> SemesterTerm? {
        guard !terms.isEmpty else { return nil }
        let d = Self.startOfDay(day)
        let begun = terms.filter { $0.start <= d }
        // Before the earliest published term — a new student in August, say.
        return begun.max(by: { $0.start < $1.start })
            ?? terms.min(by: { $0.start < $1.start })
    }

    /// True while classes are in session, gating the "today"-scoped surfaces.
    ///
    /// Unknown reads as in-session: with no calendar the app would otherwise
    /// hide Home's time slider and the today carousel forever on a device
    /// that has never reached the backend.
    func isInSession(on day: Date = Date()) -> Bool {
        terms.isEmpty || terms.contains { $0.contains(day) }
    }

    func holidays(on day: Date) -> [Holiday] {
        holidays.filter { $0.contains(day) }
    }

    /// Whether class reminders, the Live Activity and the next-class widgets
    /// stay quiet on `day`.
    ///
    /// Opting in to *any* holiday covering the day un-suppresses it: the user
    /// is saying "I have class that day", and a second overlapping holiday
    /// they never saw should not overrule that.
    func suppressesClasses(on day: Date, optedIn: Set<Int>) -> Bool {
        let covering = holidays(on: day)
        guard !covering.isEmpty else { return false }
        return !covering.contains { optedIn.contains($0.id) }
    }
}

// MARK: - Wire format

/// The payload of `GET /v3/calendar/semesters`.
///
/// Dates arrive as `YYYY-MM-DD` with no time and no zone, because every
/// consumer asks "is today in this range" — handing the clients an instant
/// would invite each platform to pick its own idea of when a day begins.
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
    /// Build from a decoded payload, dropping rows this build cannot make
    /// sense of.
    ///
    /// A malformed row costs that row, not the whole calendar: losing the
    /// calendar would silently turn suppression off everywhere, which is the
    /// failure this feature exists to prevent.
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
            // A nameless holiday would render as a blank calendar row and an
            // unexplained silence, which is worse than not having it.
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
