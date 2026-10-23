#if os(iOS)
import Foundation

/// Which new mail is left out of notifications. It only decides whether a notification is posted:
/// the mail stays in the inbox, unread. Kept on the device only and reset at sign-out
/// (https://github.com/tigerduck-app/tigerduck-app/issues/613).
nonisolated struct MailMuteSettings: Codable, Equatable, Sendable {
    var quietHours = MailQuietHours()
    var presets: Set<MailMutePreset> = []
    var rules: [MailMuteRule] = []

    func mutes(_ mail: MailSummary, arrivedAt: Date, calendar: Calendar = .current) -> Bool {
        quietHours.contains(arrivedAt, calendar: calendar)
            || presets.contains { $0.matches(mail) }
            || rules.contains { $0.matches(mail) }
    }
}

nonisolated struct MailQuietHours: Codable, Equatable, Sendable {
    var isEnabled = false
    /// Minutes after midnight.
    var start = 23 * 60
    var end = 7 * 60
    /// `Calendar` weekday numbers, 1 being Sunday.
    var weekdays: Set<Int> = Set(1...7)

    /// A window that ends on the next day belongs to the day it starts on. Equal start and end
    /// make an empty window.
    func contains(_ date: Date, calendar: Calendar) -> Bool {
        guard isEnabled, start != end else { return false }
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday, let hour = parts.hour, let minute = parts.minute else { return false }
        let time = hour * 60 + minute
        if start < end { return weekdays.contains(weekday) && start <= time && time < end }
        if time >= start { return weekdays.contains(weekday) }
        return time < end && weekdays.contains(weekday == 1 ? 7 : weekday - 1)
    }
}

nonisolated enum MailMutePreset: String, Codable, CaseIterable, Sendable {
    case bulletin
    case moodleSubmission

    static let bulletinSender = "bulletin@mail.ntust.edu.tw"
    static let moodleSender = "noreply@mail.ntust.edu.tw"
    /// The receipt's subject in Moodle's Chinese and English interfaces.
    static let moodleSubmissionSubjects = ["您已經繳交", "You have submitted your assignment submission"]

    func matches(_ mail: MailSummary) -> Bool {
        switch self {
        case .bulletin:
            MailMuteRule(field: .from, op: .is, value: Self.bulletinSender).matches(mail)
        case .moodleSubmission:
            MailMuteRule(field: .from, op: .is, value: Self.moodleSender).matches(mail)
                && Self.moodleSubmissionSubjects.contains {
                    MailMuteRule(field: .subject, op: .contains, value: $0).matches(mail)
                }
        }
    }
}

nonisolated struct MailMuteRule: Codable, Equatable, Identifiable, Sendable {
    nonisolated enum Field: String, Codable, CaseIterable, Sendable {
        case from, toOrCc, subject
    }

    nonisolated enum Operator: String, Codable, CaseIterable, Sendable {
        case contains, `is`
    }

    var id = UUID()
    var field: Field
    var op: Operator
    var value: String

    /// Case is ignored. "is" compares only the address for From and To or Cc.
    func matches(_ mail: MailSummary) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        let candidates: [String]
        switch (field, op) {
        case (.from, .contains): candidates = [mail.fromName, mail.fromAddress].compactMap { $0 }
        case (.from, .is): candidates = [mail.fromAddress].compactMap { $0 }
        case (.toOrCc, .contains): candidates = recipients(of: mail)
        case (.toOrCc, .is): candidates = recipients(of: mail).flatMap(MailAddress.parseList).map(\.address)
        case (.subject, _): candidates = [mail.subject ?? ""]
        }
        return candidates.contains { candidate in
            switch op {
            case .contains: candidate.range(of: value, options: .caseInsensitive) != nil
            case .is: candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(value) == .orderedSame
            }
        }
    }

    private func recipients(of mail: MailSummary) -> [String] {
        (mail.to ?? []) + (mail.cc ?? [])
    }
}
#endif
