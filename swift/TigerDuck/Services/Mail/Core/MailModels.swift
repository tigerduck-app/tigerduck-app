#if os(iOS)
import Foundation

/// A sender or recipient. `name` is RFC 2047-decoded and bidi-cleaned by the producer.
nonisolated struct MailAddress: Codable, Hashable, Sendable {
    var name: String?
    var address: String

    var displayName: String { name?.mailNonEmpty ?? address }

    /// One `@`, a local part and a domain containing a dot, none of them containing
    /// whitespace, a control character or an RFC 5322 special (`< > ( ) " , ; :`).
    /// Mirrors Android's `AddressParser.looksLikeAddress`. This is the gate the compose
    /// screen (Task 17) uses before sending, and it must reject a value carrying a
    /// smuggled CR/LF (header injection) as forcefully as it rejects "not an address".
    var isPlausible: Bool { Self.hasAddressShape(address) }

    /// `^[^\s@<>()",;:]+@[^\s@<>()",;:]+\.[^\s@<>()",;:]+$` plus an explicit Unicode
    /// control-character ban (`\s` alone doesn't cover every control character, e.g. BEL).
    private static let addressShapePattern = try! NSRegularExpression(
        pattern: #"^[^\s@<>()",;:\p{Cc}]+@[^\s@<>()",;:\p{Cc}]+\.[^\s@<>()",;:\p{Cc}]+$"#
    )

    private static func hasAddressShape(_ candidate: String) -> Bool {
        let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        return addressShapePattern.firstMatch(in: candidate, range: range) != nil
    }

    /// Parses `"Name" <a@b>, c@d; Name <e@f>` — commas and semicolons separate, except
    /// inside quotes or angle brackets. A backslash inside quotes escapes the character
    /// after it (matching `MailReplyComposer.formatted`'s escaping of `"` and `\`), so an
    /// escaped quote never closes the quoted span early.
    static func parseList(_ raw: String) -> [MailAddress] {
        var pieces: [String] = []
        var current = ""
        var inQuotes = false
        var inAngle = false
        var escaped = false
        for character in raw {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\", inQuotes {
                current.append(character)
                escaped = true
                continue
            }
            if character == "\"" { inQuotes.toggle() }
            if character == "<", !inQuotes { inAngle = true }
            if character == ">", !inQuotes { inAngle = false }
            if (character == "," || character == ";") && !inQuotes && !inAngle {
                pieces.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        pieces.append(current)
        return pieces.compactMap(parseOne)
    }

    /// A token whose address portion doesn't have a plain `local@domain` shape (an
    /// embedded whitespace, control character or RFC 5322 special — including a
    /// smuggled CR/LF) is dropped rather than becoming a `MailAddress`.
    private static func parseOne(_ raw: String) -> MailAddress? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close {
            let address = trimmed[trimmed.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            guard hasAddressShape(address) else { return nil }
            var name = trimmed[..<open].trimmingCharacters(in: .whitespaces)
            if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") {
                name = unescaped(String(name.dropFirst().dropLast()))
            }
            return MailAddress(name: name.mailNonEmpty, address: address)
        }
        guard hasAddressShape(trimmed) else { return nil }
        return MailAddress(name: nil, address: trimmed)
    }

    /// Undoes the backslash-escaping `MailReplyComposer.formatted` applies to `"` and `\`
    /// inside a quoted display name: a backslash always escapes the character after it.
    private static func unescaped(_ text: String) -> String {
        var result = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            if character == "\\", let next = iterator.next() {
                result.append(next)
            } else {
                result.append(character)
            }
        }
        return result
    }
}

/// One row of a folder list. Every field is optional or primitive, so a cache file
/// written by an older build still decodes; anything else is deleted and refetched.
nonisolated struct MailSummary: Codable, Hashable, Sendable, Identifiable {
    var uid: UInt32
    var fromName: String?
    var fromAddress: String?
    var to: [String]?
    var cc: [String]?
    var subject: String?
    var date: Date?
    var isSeen: Bool
    var isAnswered: Bool
    var isDeleted: Bool
    var size: Int?
    var hasAttachments: Bool
    var isExternal: Bool

    var id: UInt32 { uid }
}

nonisolated struct MailFlags: Equatable, Sendable {
    var seen: Bool
    var answered: Bool
    var deleted: Bool
}

nonisolated struct MailBodyPart: Codable, Hashable, Sendable {
    /// IMAP section path, e.g. `"2"` or `"1.2"`.
    var section: String
    /// Lowercased `type/subtype`.
    var contentType: String
    var charset: String?
    var transferEncoding: String?
    /// RFC 2047-decoded and bidi-cleaned.
    var filename: String?
    /// Without angle brackets.
    var contentID: String?
    var size: Int?
    var isAttachment: Bool
}

nonisolated struct MailInlineImage: Codable, Hashable, Sendable {
    var mimeType: String
    var data: Data
}

nonisolated struct MailMessageDetail: Codable, Sendable {
    var summary: MailSummary
    var messageID: String?
    var inReplyTo: String?
    var references: [String]?
    var parts: [MailBodyPart]
    var textBody: String?
    var htmlBody: String?
    /// Content-ID (no angle brackets) → image, for inline `cid:` images only.
    var inlineImages: [String: MailInlineImage]?

    var attachments: [MailBodyPart] { parts.filter(\.isAttachment) }
}

nonisolated struct MailFolderPage: Codable, Sendable {
    var folder: String
    var uidValidity: UInt32
    var messageCount: Int
    /// Newest first.
    var summaries: [MailSummary]
    /// Lowest sequence number loaded; nil once the oldest message is loaded.
    var oldestLoadedSequence: Int?
}

nonisolated struct MailboxStatusInfo: Equatable, Sendable {
    var uidValidity: UInt32
    var uidNext: UInt32
    var unseen: Int?
}

nonisolated extension String {
    /// `nil` for an empty or whitespace-only string.
    var mailNonEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
#endif
