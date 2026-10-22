#if os(iOS)
import Foundation

nonisolated struct MailAddress: Codable, Hashable, Sendable {
    var name: String?
    var address: String

    var displayName: String { name?.mailNonEmpty ?? address }

    var isPlausible: Bool { Self.hasAddressShape(address) }

    private static let addressShapePattern = try! NSRegularExpression(
        pattern: #"^[^\s@<>()",;:\p{Cc}]+@[^\s@<>()",;:\p{Cc}]+\.[^\s@<>()",;:\p{Cc}]+$"#
    )

    private static func hasAddressShape(_ candidate: String) -> Bool {
        let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        return addressShapePattern.firstMatch(in: candidate, range: range) != nil
    }

    static func parseList(_ raw: String) -> [MailAddress] {
        splitTopLevel(raw).compactMap(parseOne)
    }

    static func parseSender(_ raw: String) -> MailAddress? {
        if let parsed = parseList(raw).first { return parsed }
        return splitTopLevel(raw).lazy.compactMap(nameOnly).first
    }

    private static func nameOnly(_ raw: String) -> MailAddress? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close else {
            return nil
        }
        var name = trimmed[..<open].trimmingCharacters(in: .whitespaces)
        if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") {
            name = unescaped(String(name.dropFirst().dropLast()))
        }
        guard let kept = name.mailNonEmpty else { return nil }
        return MailAddress(name: kept, address: "")
    /// The `From:` of an incoming mail, keeping the display name when the address is unusable.
    /// Mail2000 puts `From: "Mail Deliver System" <MAILER-DAEMON>` on every delivery-failure
    /// notice; `parseOne` drops that domainless token, leaving "(No sender)". Here the name
    /// survives with an empty address, not the raw token: `address` is what `MailWarnings`
    /// classifies and what a reply goes to, and `MAILER-DAEMON` is not routable. An empty address
    /// makes `isPlausible` false, so `MailReplyComposer.replyRecipients` and compose validation
    /// leave the sender out. Only `From` uses this: `Reply-To`, `To`, `Cc`, `mailto:` and compose
    /// fields become recipients, so they stay on the strict `parseList`.
    }

    private static func splitTopLevel(_ raw: String) -> [String] {
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
        return pieces
    }

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

nonisolated struct MailSummary: Codable, Hashable, Sendable {
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
}

nonisolated struct MailFlags: Equatable, Sendable {
    var seen: Bool
    var answered: Bool
    var deleted: Bool
}

nonisolated struct MailBodyPart: Codable, Hashable, Sendable {
    var section: String
    var contentType: String
    var charset: String?
    var transferEncoding: String?
    var filename: String?
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
    var returnPath: String? = nil
    var replyTo: String? = nil
    var parts: [MailBodyPart]
    var textBody: String?
    var htmlBody: String?
    var inlineImages: [String: MailInlineImage]?

    var attachments: [MailBodyPart] { parts.filter(\.isAttachment) }
}

nonisolated struct MailFolderPage: Codable, Sendable {
    var folder: String
    var uidValidity: UInt32
    var messageCount: Int
    var summaries: [MailSummary]
    var oldestLoadedSequence: Int?
    var uidNext: UInt32? = nil
    var windowUIDs: ClosedRange<UInt32>? = nil
    var fetchedAt: Date? = nil

    static func span(of uids: [UInt32]) -> ClosedRange<UInt32>? {
        guard let low = uids.min(), let high = uids.max() else { return nil }
        return low...high
    }
}

nonisolated struct MailboxStatusInfo: Equatable, Sendable {
    var uidValidity: UInt32
    var uidNext: UInt32
}

nonisolated extension String {
    var mailNonEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
#endif
