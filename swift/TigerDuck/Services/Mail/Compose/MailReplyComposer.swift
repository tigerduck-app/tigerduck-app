#if os(iOS)
import Foundation

/// The parts of an opened mail that reply and forward need.
nonisolated struct MailOriginal: Sendable {
    var from: MailAddress?
    var to: [MailAddress]
    var cc: [MailAddress]
    var subject: String
    var date: Date?
    var messageID: String?
    var references: [String]
    var bodyText: String
}

/// Reply and forward rules (design doc §6.4).
nonisolated enum MailReplyComposer {
    /// RFC 5322 specials: a display name containing any of these must be quoted so the
    /// formatted address round-trips through `MailAddress.parseList`. Matches Android's
    /// `ComposeRules.formatOne`.
    private static let nameSpecials = CharacterSet(charactersIn: ",;\"<>():@\\")

    static func replySubject(_ subject: String) -> String {
        hasPrefix(subject, ["re:"]) ? subject : "Re: \(subject)"
    }

    static func forwardSubject(_ subject: String) -> String {
        hasPrefix(subject, ["fwd:", "fw:"]) ? subject : "Fwd: \(subject)"
    }

    /// Blank lines, then 「於 {date}，{sender} 寫道：」 and the original with `> ` on every line.
    static func quotedBody(of original: MailOriginal, dateText: String) -> String {
        let quoted = normalizedLines(original.bodyText).map { "> \($0)" }.joined(separator: "\n")
        return "\n\n\(header(original, dateText: dateText))\n\(quoted)"
    }

    /// Forwards carry a structured header block — blank line, blank line, the forwarded-
    /// message marker, From/Date/Subject/To, blank line, then the original text unquoted
    /// underneath (design doc §6.4; matches Android's `ComposePrefill.forward`). The four
    /// header keys plus `school_mail_details_to` are `shared`-group keys already added by
    /// the Android strings task (Task 18), not new `apple`-group ones.
    static func forwardBody(of original: MailOriginal, dateText: String) -> String {
        let block = [
            String(localized: "school_mail_forwarded_header"),
            String(format: String(localized: "school_mail_forward_from"), formatted(original.from)),
            String(format: String(localized: "school_mail_forward_date"), dateText),
            String(format: String(localized: "school_mail_forward_subject"), original.subject),
            String(format: String(localized: "school_mail_details_to"), formatted(original.to)),
        ].joined(separator: "\n")
        return "\n\n\(block)\n\n\(normalizedLines(original.bodyText).joined(separator: "\n"))"
    }

    /// "Name <address>" when a name is present, else the bare address — for the
    /// human-readable From/To lines in a forward's header block (not a MIME header) and
    /// for a compose recipient field. A name containing an RFC 5322 special is quoted with
    /// `"` and has `\` and `"` backslash-escaped so it parses back through
    /// `MailAddress.parseList`. Matches Android's `ComposeRules.formatOne`.
    static func formatted(_ address: MailAddress) -> String {
        guard let name = address.name?.mailNonEmpty else { return address.address }
        guard name.unicodeScalars.contains(where: nameSpecials.contains) else {
            return "\(name) <\(address.address)>"
        }
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\" <\(address.address)>"
    }

    static func formatted(_ address: MailAddress?) -> String {
        address.map(formatted) ?? ""
    }

    static func formatted(_ addresses: [MailAddress]) -> String {
        addresses.map(formatted).joined(separator: ", ")
    }

    /// Reply goes to Reply-To (else From). Reply all also copies the original To and Cc,
    /// minus my own address and anything already addressed (case-insensitive).
    static func replyRecipients(
        to original: MailOriginal,
        replyTo: [MailAddress],
        me: String,
        replyAll: Bool
    ) -> (to: [MailAddress], cc: [MailAddress]) {
        let primary = !replyTo.isEmpty ? replyTo : (original.from.map { [$0] } ?? [])
        var seen = Set(primary.map { $0.address.lowercased() })
        seen.insert(me.lowercased())
        guard replyAll else { return (primary, []) }
        let cc = (original.to + original.cc).filter { seen.insert($0.address.lowercased()).inserted }
        return (primary, cc)
    }

    static func threadingHeaders(for original: MailOriginal) -> (inReplyTo: String?, references: [String]) {
        guard let id = original.messageID else { return (nil, original.references) }
        return (id, original.references + [id])
    }

    private static func header(_ original: MailOriginal, dateText: String) -> String {
        String(format: String(localized: "school_mail_quote_header"), dateText, original.from?.displayName ?? "")
    }

    private static func normalizedLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    private static func hasPrefix(_ subject: String, _ prefixes: [String]) -> Bool {
        let lowered = subject.trimmingCharacters(in: .whitespaces).lowercased()
        return prefixes.contains { lowered.hasPrefix($0) }
    }
}
#endif
