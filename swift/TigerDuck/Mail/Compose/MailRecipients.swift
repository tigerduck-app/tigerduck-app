#if os(iOS)
import Foundation

/// The recipient fields compose sends: written out for a prefill, and read back token by token
/// so a token that cannot be sent is reported, not dropped.
nonisolated enum MailRecipients {
    struct Parsed {
        var to: [MailAddress]
        var cc: [MailAddress]
        var bcc: [MailAddress]
        var invalid: [String]
    }

    static func parse(to: String, cc: String, bcc: String) -> Parsed {
        let (toList, toInvalid) = parse(to)
        let (ccList, ccInvalid) = parse(cc)
        let (bccList, bccInvalid) = parse(bcc)
        return Parsed(to: toList, cc: ccList, bcc: bccList, invalid: toInvalid + ccInvalid + bccInvalid)
    }

    static func format(_ addresses: [MailAddress]) -> String {
        addresses.map { address in
            guard let name = address.name?.mailNonEmpty else { return address.address }
            let needsQuotes = name.contains(",") || name.contains(";")
            return needsQuotes ? "\"\(name)\" <\(address.address)>" : "\(name) <\(address.address)>"
        }.joined(separator: ", ")
    }

    /// Splits on top-level commas and semicolons like `MailAddress.parseList`, which drops a token
    /// it cannot parse where compose needs it back to report it. A token is invalid when it is no
    /// plausible address or its address is not ASCII: the school SMTP server has no SMTPUTF8, and
    /// only compose rejects it, never the parser incoming mail uses to show a "From".
    static func parse(_ raw: String) -> (addresses: [MailAddress], invalid: [String]) {
        var addresses: [MailAddress] = []
        var invalid: [String] = []
        for token in splitTopLevel(raw) {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let address = sendableAddress(trimmed) {
                addresses.append(address)
            } else {
                invalid.append(trimmed)
            }
        }
        return (addresses, invalid)
    }

    static func sendableAddress(_ token: String) -> MailAddress? {
        guard let address = MailAddress.parseList(token).first,
              address.address.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        return address
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
}
#endif
