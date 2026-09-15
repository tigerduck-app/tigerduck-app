#if os(iOS)
import Foundation

/// A sender or recipient. `name` is RFC 2047-decoded and bidi-cleaned by the producer.
nonisolated struct MailAddress: Codable, Hashable, Sendable {
    var name: String?
    var address: String

    var displayName: String { name?.mailNonEmpty ?? address }

    /// Loose check before sending: one `@`, a dot in the domain, no spaces.
    var isPlausible: Bool {
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !address.contains(" ")
    }

    /// Parses `"Name" <a@b>, c@d; Name <e@f>` — commas and semicolons separate, except
    /// inside quotes or angle brackets.
    static func parseList(_ raw: String) -> [MailAddress] {
        var pieces: [String] = []
        var current = ""
        var inQuotes = false
        var inAngle = false
        for character in raw {
            if character == "\"" { inQuotes.toggle() }
            if character == "<" { inAngle = true }
            if character == ">" { inAngle = false }
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

    private static func parseOne(_ raw: String) -> MailAddress? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close {
            let address = trimmed[trimmed.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            var name = trimmed[..<open].trimmingCharacters(in: .whitespaces)
            if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") {
                name = String(name.dropFirst().dropLast())
            }
            return MailAddress(name: name.mailNonEmpty, address: address)
        }
        return MailAddress(name: nil, address: trimmed)
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
