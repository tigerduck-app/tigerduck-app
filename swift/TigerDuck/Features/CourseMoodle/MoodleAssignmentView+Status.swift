#if os(iOS)
import SwiftUI

/// What the assignment page says of the deadline, the hand-in and the grade, and how it writes
/// lengths of time and times.
extension MoodleAssignmentView {
    /// The badge beside the submission's heading.
    enum Badge: Equatable {
        case notSubmitted
        /// Handed in, with no due date or no time to measure against it.
        case submitted
        case early(TimeInterval)
        case late(TimeInterval)

        var text: String {
            switch self {
            case .notSubmitted: String(localized: "assignment_detail_not_submitted")
            case .submitted: String(localized: "assignment_status_submitted")
            case .early(let lead):
                String(format: String(localized: "assignment_detail_submitted_early"), durationText(lead))
            case .late(let delay):
                String(format: String(localized: "assignment_detail_submitted_late_by"), durationText(delay))
            }
        }

        var tint: Color {
            switch self {
            case .notSubmitted: Color.textSecondary
            case .submitted, .early: .green
            case .late: Color.badgeRed
            }
        }

        var symbol: String { self == .notSubmitted ? "circle" : "checkmark" }
    }

    /// The line under the due time.
    enum Deadline: Equatable {
        /// `urgent` while the account has not handed it in.
        case left(TimeInterval, urgent: Bool)
        /// Passed, with the assignment handed in or not one Moodle takes online.
        case passed
        /// Passed without the account handing it in.
        case overdue(TimeInterval)

        var text: String {
            switch self {
            case .left(let time, _): String(format: String(localized: "assignment_detail_time_left"), durationText(time))
            case .passed: String(localized: "assignment_detail_due_passed")
            case .overdue(let time): String(format: String(localized: "assignment_detail_overdue_by"), durationText(time))
            }
        }

        var tint: Color {
            switch self {
            case .left(_, urgent: true): .orange
            case .left, .passed: Color.textSecondary
            case .overdue: Color.badgeRed
            }
        }

        var isEmphasized: Bool {
            switch self {
            case .left(_, let urgent): urgent
            case .passed: false
            case .overdue: true
            }
        }

        var isOverdue: Bool {
            if case .overdue = self { true } else { false }
        }
    }

    /// A grade split for the grade card.
    struct Score: Equatable {
        let value: String
        let max: String?

        var spoken: String {
            guard let max else { return value }
            return "\(value), \(String(format: String(localized: "course_moodle_grade_out_of"), max))"
        }
    }

    /// Whether the account handed it in: the fetched submission says, else Home's row. Nil while
    /// neither has answered, and for an assignment Moodle takes nothing online for.
    static func isSubmitted(
        record: MoodleAssignmentRecord, listed: SDAssignment?, submission: MoodleAssignmentSubmission?
    ) -> Bool? {
        guard !record.noSubmissions else { return nil }
        return submission?.isSubmitted ?? listed?.isCompleted
    }

    /// Nil while nothing says whether it is handed in.
    static func badge(isSubmitted: Bool?, submittedAt: Date?, due: Date?) -> Badge? {
        guard let isSubmitted else { return nil }
        guard isSubmitted else { return .notSubmitted }
        guard let due, let submittedAt else { return .submitted }
        return submittedAt > due ? .late(submittedAt.timeIntervalSince(due)) : .early(due.timeIntervalSince(submittedAt))
    }

    static func deadline(due: Date, isSubmitted: Bool?, now: Date) -> Deadline {
        guard due < now else { return .left(due.timeIntervalSince(now), urgent: isSubmitted == false) }
        return isSubmitted == false ? .overdue(now.timeIntervalSince(due)) : .passed
    }

    /// The card shows what was handed in, or a draft's files and text, under its time.
    static func showsCard(_ submission: MoodleAssignmentSubmission) -> Bool {
        !submission.files.isEmpty || submission.onlineText != nil || submission.submittedAt != nil
    }

    /// A grade of points over a maximum, as Moodle writes "85.00 / 100.00", splits into the two,
    /// each without the zeros ending its decimals. Any other grade, such as a letter, a percentage
    /// or a scale's word, stays whole.
    static func score(of grade: String) -> Score {
        let parts = grade.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, parts.allSatisfy({ $0.wholeMatch(of: /-?[0-9]+([.,][0-9]+)?/) != nil }) else {
            return Score(value: grade, max: nil)
        }
        return Score(value: withoutTrailingZeros(parts[0]), max: withoutTrailingZeros(parts[1]))
    }

    private static func withoutTrailingZeros(_ number: String) -> String {
        guard number.contains(where: { $0 == "." || $0 == "," }) else { return number }
        var trimmed = number
        while trimmed.last == "0" { trimmed.removeLast() }
        if trimmed.last == "." || trimmed.last == "," { trimmed.removeLast() }
        return trimmed
    }

    /// At most two units, rounded down so the time left never reads longer than it is; under a
    /// minute reads as one minute.
    static func durationText(_ seconds: TimeInterval, locale: Locale = .autoupdatingCurrent) -> String {
        Duration.seconds(max(seconds, 60)).formatted(
            .units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2,
                   fractionalPart: .hide(rounded: .down))
            .locale(locale)
        )
    }

    /// "Thu, Oct 15 at 20:03": the month, day, weekday and time, in Taipei.
    static func timeText(_ date: Date, locale: Locale = .autoupdatingCurrent) -> String {
        formatted(date, template: "MMMdEEEHHmm", locale: locale)
    }

    /// "Tue 23:59", with the app's weekday captions.
    static func weekdayTimeText(_ date: Date, locale: Locale = .autoupdatingCurrent) -> String {
        "\(NextClassResolver.Day.later(weekday: date.scheduleWeekday).headline) \(formatted(date, template: "HHmm", locale: locale))"
    }

    static func monthText(_ date: Date, locale: Locale = .autoupdatingCurrent) -> String {
        formatted(date, template: "MMM", locale: locale)
    }

    /// A page with many comments writes a time for each, so each template's formatter is kept.
    private static var formatters: [String: DateFormatter] = [:]

    private static func formatted(_ date: Date, template: String, locale: Locale) -> String {
        let key = "\(template) \(locale.identifier)"
        if let formatter = formatters[key] { return formatter.string(from: date) }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = AppConstants.taipeiCalendar
        formatter.timeZone = AppConstants.taipeiTimeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        formatters[key] = formatter
        return formatter.string(from: date)
    }
}
#endif
