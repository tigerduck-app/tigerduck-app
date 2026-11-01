#if os(iOS)
import Foundation
import TigerDuckCore

/// Kept on the device only and reset at sign-out
/// (https://github.com/tigerduck-app/tigerduck-app/issues/613).
nonisolated struct MailMuteSettings: Codable, Equatable, Sendable {
    var quietHours = MailQuietHours()
    var presets: Set<MailMutePreset> = []
    var rules: [MailMuteRule] = []

    func mutes(_ mail: MailSummary, arrivedAt: Date, calendar: Calendar = TaipeiTime.calendar) -> Bool {
        quietHours.contains(arrivedAt, calendar: calendar)
            || presets.contains { $0.matches(mail) }
            || rules.contains { $0.matches(mail) }
    }
}

nonisolated struct MailQuietHours: Codable, Equatable, Sendable {
    var isEnabled = false
    var startMinute = 23 * 60
    var endMinute = 7 * 60
    /// `Calendar` weekday numbers, 1 being Sunday.
    var weekdays: Set<Int> = Set(1...7)

    enum CodingKeys: String, CodingKey {
        case isEnabled, weekdays
        case startMinute = "start"
        case endMinute = "end"
    }

    func contains(_ date: Date, calendar: Calendar = TaipeiTime.calendar) -> Bool {
        guard isEnabled else { return false }
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday, let hour = parts.hour, let minute = parts.minute,
              let startDay = startDay(ofWindowAt: hour * 60 + minute, on: weekday) else { return false }
        return weekdays.contains(startDay)
    }

    private func startDay(ofWindowAt minute: Int, on weekday: Int) -> Int? {
        if startMinute < endMinute { return (startMinute..<endMinute).contains(minute) ? weekday : nil }
        if startMinute == endMinute { return nil }
        if minute >= startMinute { return weekday }
        return minute < endMinute ? (weekday == 1 ? 7 : weekday - 1) : nil
    }
}

nonisolated enum MailMutePreset: String, Codable, CaseIterable, Sendable {
    case bulletin
    case moodleSubmission

    static let bulletinSender = "bulletin@mail.ntust.edu.tw"
    static let moodleSender = "noreply@mail.ntust.edu.tw"
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

private nonisolated extension KeyedDecodingContainer {
    func decode<T: Decodable>(_ key: Key, default fallback: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback()
    }
}

nonisolated extension MailMuteSettings {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MailMuteSettings()
        quietHours = try container.decode(.quietHours, default: defaults.quietHours)
        presets = try container.decode(.presets, default: defaults.presets)
        rules = try container.decode(.rules, default: defaults.rules)
    }
}

nonisolated extension MailQuietHours {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MailQuietHours()
        isEnabled = try container.decode(.isEnabled, default: defaults.isEnabled)
        startMinute = try container.decode(.startMinute, default: defaults.startMinute)
        endMinute = try container.decode(.endMinute, default: defaults.endMinute)
        weekdays = try container.decode(.weekdays, default: defaults.weekdays)
    }
}

nonisolated extension MailMuteRule {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(.id, default: UUID())
        field = try container.decode(.field, default: .from)
        op = try container.decode(.op, default: .contains)
        value = try container.decode(.value, default: "")
    }
}
#endif
