#if os(iOS)
import Foundation

nonisolated struct OutgoingAttachment: Equatable, Sendable {
    var filename: String
    var mimeType: String
    var data: Data
}

nonisolated struct OutgoingMail: Sendable {
    var from: MailAddress
    var to: [MailAddress]
    var cc: [MailAddress]
    var bcc: [MailAddress]
    var subject: String
    var body: String
    var inReplyTo: String?
    var references: [String]
    var attachments: [OutgoingAttachment]

    /// SMTP `RCPT TO` list: To, Cc and Bcc, deduplicated case-insensitively. Bcc never
    /// appears in the headers.
    var envelopeRecipients: [String] {
        var seen = Set<String>()
        return (to + cc + bcc).map(\.address).filter { seen.insert($0.lowercased()).inserted }
    }
}

/// Builds the 7-bit RFC 5322 message TigerDuck sends (design doc §8.4): UTF-8 plain text
/// in quoted-printable, RFC 2047 headers, RFC 2231 attachment names.
nonisolated enum MailMessageBuilder {
    static func makeMessageID() -> String {
        "<\(UUID().uuidString.lowercased())@\(MailConstants.addressDomain)>"
    }

    static func build(
        _ mail: OutgoingMail,
        messageID: String,
        date: Date,
        boundary: String = "TigerDuck-\(UUID().uuidString)"
    ) -> Data {
        var lines: [String] = []
        lines.append("From: \(header(for: mail.from))")
        if !mail.to.isEmpty { lines.append("To: \(mail.to.map(header(for:)).joined(separator: ", "))") }
        if !mail.cc.isEmpty { lines.append("Cc: \(mail.cc.map(header(for:)).joined(separator: ", "))") }
        lines.append("Subject: \(encodedWords(mail.subject))")
        lines.append("Date: \(rfc5322Date(date))")
        lines.append("Message-ID: \(sanitizedHeaderValue(messageID))")
        if let inReplyTo = mail.inReplyTo, let token = threadingToken(inReplyTo) {
            lines.append("In-Reply-To: \(token)")
        }
        if !mail.references.isEmpty {
            let tokens = mail.references.compactMap(threadingToken)
            if !tokens.isEmpty { lines.append("References: \(tokens.joined(separator: " "))") }
        }
        lines.append("MIME-Version: 1.0")

        let textPart = [
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: quoted-printable",
            "",
            quotedPrintable(mail.body),
        ]
        if mail.attachments.isEmpty {
            lines += textPart
        } else {
            lines.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
            lines.append("")
            lines.append("--\(boundary)")
            lines += textPart
            for attachment in mail.attachments {
                lines.append("--\(boundary)")
                lines.append("Content-Type: \(sanitizedMimeType(attachment.mimeType)); name=\"\(contentTypeName(attachment.filename))\"")
                lines.append("Content-Transfer-Encoding: base64")
                lines.append("Content-Disposition: attachment; \(dispositionFilename(attachment.filename))")
                lines.append("")
                lines += attachment.data
                    .base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
                    .components(separatedBy: "\r\n")
            }
            lines.append("--\(boundary)--")
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    // MARK: Headers

    /// `address.address` is sanitized here as defense in depth: `MailAddress.isPlausible`
    /// (used by the compose screen before send) and `MailAddress.parseList` already
    /// reject a value with a plain-shape violation, but a `MailAddress` can also be
    /// constructed directly (a cache, a demo fixture, a future call site) without going
    /// through either gate, so this must never emit a raw control character regardless of
    /// how the address got here.
    static func header(for address: MailAddress) -> String {
        let sanitizedAddress = sanitizedHeaderValue(address.address)
        guard let name = address.name?.mailNonEmpty else { return sanitizedAddress }
        if isPlainASCII(name) {
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\" <\(sanitizedAddress)>"
        }
        return "\(encodedWords(name)) <\(sanitizedAddress)>"
    }

    /// ASCII text stays as is; anything else becomes UTF-8 base64 encoded words of at most
    /// 45 bytes each (72 characters, under RFC 2047's 75), folded with CRLF + space.
    static func encodedWords(_ text: String) -> String {
        guard !isPlainASCII(text) else { return text }
        var words: [String] = []
        var chunk = ""
        for character in text {
            let candidate = chunk + String(character)
            if candidate.utf8.count > 45, !chunk.isEmpty {
                words.append(encodedWord(chunk))
                chunk = String(character)
            } else {
                chunk = candidate
            }
        }
        if !chunk.isEmpty { words.append(encodedWord(chunk)) }
        return words.joined(separator: "\r\n ")
    }

    private static func encodedWord(_ text: String) -> String {
        "=?UTF-8?B?\(Data(text.utf8).base64EncodedString())?="
    }

    private static func isPlainASCII(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 0x20 && $0.value != 0x7F } && !text.contains("=?")
    }

    private static func rfc5322Date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Taipei")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    /// A header value (an address, a Message-ID token, a References chain) never
    /// legitimately contains a control character; stripping every one (not just CR/LF)
    /// defangs a CRLF header-injection attempt smuggled in through a hostile address,
    /// Message-ID, In-Reply-To or References value. Bcc is never written as a header at
    /// all (see `OutgoingMail.envelopeRecipients`), so this only has to keep every other
    /// header from growing an extra line.
    private static func sanitizedHeaderValue(_ raw: String) -> String {
        String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
    }

    /// One `In-Reply-To`/`References` `msg-id`, or `nil` for one that must not be written.
    ///
    /// These are the only header values this builder echoes back from a *received* mail, and a
    /// received `Message-ID` is attacker-controlled free text. RFC 5322 defines `msg-id` as
    /// ASCII, and the school's Mail2000 announces neither SMTPUTF8 nor 8BITMIME, so a UTF-8
    /// byte here is the one way raw 8-bit data can still reach a 7-bit wire — everything else
    /// is RFC 2047-encoded (subject, display name), quoted-printable (body) or validated
    /// ASCII (the recipient addresses, at `MailComposeViewModel.parseRecipients`).
    ///
    /// Dropped whole rather than stripped down to its ASCII characters: a mangled `msg-id`
    /// identifies no message on any server, so it would only be junk in the header while still
    /// claiming to thread. Losing the threading reference is the lesser failure.
    private static func threadingToken(_ raw: String) -> String? {
        let sanitized = sanitizedHeaderValue(raw)
        guard !sanitized.isEmpty, isPlainASCII(sanitized) else { return nil }
        return sanitized
    }

    // MARK: Attachment names

    /// RFC 2045 `type/subtype`, restricted to token characters (no whitespace, no
    /// control character, no `/` beyond the one separator). Anything else — including a
    /// value carrying a smuggled CRLF — falls back to a safe default rather than being
    /// written into the header verbatim.
    private static let mimeTypePattern = try! NSRegularExpression(
        pattern: #"^[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*$"#
    )

    private static func sanitizedMimeType(_ raw: String) -> String {
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        return mimeTypePattern.firstMatch(in: raw, range: range) != nil ? raw : "application/octet-stream"
    }

    private static func contentTypeName(_ filename: String) -> String {
        isPlainASCII(filename) && !filename.contains("\"") ? filename : encodedWord(filename)
    }

    static func dispositionFilename(_ filename: String) -> String {
        if isPlainASCII(filename), !filename.contains("\""), !filename.contains("\\") {
            return "filename=\"\(filename)\""
        }
        let attrChars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~")
        return "filename*=UTF-8''\(filename.addingPercentEncoding(withAllowedCharacters: attrChars) ?? filename)"
    }

    // MARK: Body

    /// RFC 2045 §6.7's line-length cap the quoted-printable encoder wraps at — shared by
    /// the real encoder (`encodeLine`) and its size estimate (`quotedPrintableUpperBound`)
    /// so the two can never drift apart. A gap here (the estimate wrapping later than the
    /// encoder actually does) undercounts every soft break past the first for a long
    /// unbroken run, which is exactly the kind of gap that turns an "upper bound" into one
    /// that isn't.
    private static let qpLineLength = 75

    static func quotedPrintable(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map(encodeLine)
            .joined(separator: "\r\n")
    }

    private static func encodeLine(_ line: String) -> String {
        let bytes = Array(line.utf8)
        var tokens: [String] = []
        for (index, byte) in bytes.enumerated() {
            let isLast = index == bytes.count - 1
            switch byte {
            case 0x21...0x3C, 0x3E...0x7E:
                tokens.append(String(UnicodeScalar(byte)))
            case 0x20, 0x09:
                tokens.append(isLast ? String(format: "=%02X", byte) : String(UnicodeScalar(byte)))
            default:
                tokens.append(String(format: "=%02X", byte))
            }
        }
        var output = ""
        var length = 0
        for token in tokens {
            if length + token.count > qpLineLength {
                output += "=\r\n"
                length = 0
            }
            output += token
            length += token.count
        }
        return output
    }

    // MARK: Size estimate

    /// A true upper bound on the byte size `build(_:messageID:date:boundary:)` would
    /// produce for this body and these attachment sizes, used to gate the SMTP SIZE limit
    /// (`MailConstants.maxEncodedMessageBytes`) before compose ever touches the network.
    /// Simulates quoted-printable encoding byte-for-byte, counting real UTF-8 bytes rather
    /// than UTF-16 code units: a printable ASCII byte (33-126, excluding `=`) costs 1
    /// output byte, everything else (UTF-8 continuation/lead bytes of non-ASCII text,
    /// control characters, `=` itself) costs 3 (`=XX`), and a soft line break (`=CRLF`, 3
    /// bytes) is charged at the same `qpLineLength` column `encodeLine` itself wraps at.
    /// Every rule here rounds toward the real encoder's worst case (or worse), so this can
    /// only over-count, never under-count -- undercounting is what let CJK bodies (whose
    /// UTF-8 encoding is already ~3 bytes/char, each of which then triples again under QP)
    /// sail past a naive `characters * 3` estimate.
    static func estimateEncodedSize(body: String, attachmentByteCounts: [Int] = []) -> Int {
        let text = quotedPrintableUpperBound(body)
        let attachments = attachmentByteCounts.reduce(0) { total, bytes in
            total + ((bytes + 56) / 57) * 78 + 512
        }
        return text + attachments + 4096
    }

    private static func quotedPrintableUpperBound(_ body: String) -> Int {
        var total = 0
        var column = 0
        for byte in body.utf8 {
            let value = Int(byte)
            let cost = (value >= 33 && value <= 126 && value != 0x3D) ? 1 : 3
            if column + cost > qpLineLength {
                total += 3
                column = 0
            }
            total += cost
            column += cost
        }
        return total
    }
}
#endif
