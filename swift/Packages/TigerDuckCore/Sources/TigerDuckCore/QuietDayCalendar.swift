import Foundation

/// The days the school holds no classes: a day outside every term, or a day of a holiday the user
/// has not chosen to keep classes on. With no term known, every day is in session.
public struct QuietDayCalendar: Sendable {
    /// Taipei days from `start` to `end`, both included.
    public struct Span: Hashable, Sendable {
        public let start: Date
        public let end: Date

        public init(start: Date, end: Date) {
            self.start = start
            self.end = end
        }

        public func contains(_ day: Date) -> Bool {
            let start = TaipeiTime.calendar.startOfDay(for: day)
            return start >= self.start && start <= end
        }
    }

    public struct Holiday: Hashable, Sendable {
        public let id: Int
        public let span: Span

        public init(id: Int, span: Span) {
            self.id = id
            self.span = span
        }
    }

    public let terms: [Span]
    public let holidays: [Holiday]
    /// The holidays on which the user still has classes.
    public let optedIn: Set<Int>

    public init(terms: [Span], holidays: [Holiday], optedIn: Set<Int> = []) {
        self.terms = terms
        self.holidays = holidays
        self.optedIn = optedIn
    }

    public func isInSession(_ day: Date) -> Bool {
        terms.isEmpty || terms.contains { $0.contains(day) }
    }

    public func suppressesClasses(on day: Date) -> Bool {
        let covering = holidays.filter { $0.span.contains(day) }
        return !covering.isEmpty && !covering.contains { optedIn.contains($0.id) }
    }

    public func isClassDay(_ day: Date) -> Bool {
        isInSession(day) && !suppressesClasses(on: day)
    }

    /// The day keys of the days out of session from `now`'s day to `days` days on, and of every day
    /// a holiday takes classes from, past ones too.
    public func quietDayKeys(from now: Date, days: Int) -> Set<String> {
        let calendar = TaipeiTime.calendar
        let today = calendar.startOfDay(for: now)
        var keys = Set((0..<days).compactMap { offset -> String? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today), !isInSession(day) else { return nil }
            return TaipeiTime.dayKey(for: day)
        })
        for holiday in holidays {
            var day = calendar.startOfDay(for: holiday.span.start)
            let last = calendar.startOfDay(for: holiday.span.end)
            while day <= last {
                if suppressesClasses(on: day) { keys.insert(TaipeiTime.dayKey(for: day)) }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return keys
    }
}
