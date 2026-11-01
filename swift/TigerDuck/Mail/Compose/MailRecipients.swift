#if os(iOS)
import Foundation

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

    /// RFC 5322 specials, which a display name may hold only quoted.
    private static let nameSpecials = CharacterSet(charactersIn: ",;\"<>():@\\")

    static func format(_ address: MailAddress) -> String {
        guard let name = address.name?.mailNonEmpty else { return address.address }
        guard !address.address.isEmpty else { return name }
        guard name.unicodeScalars.contains(where: nameSpecials.contains) else {
            return "\(name) <\(address.address)>"
        }
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\" <\(address.address)>"
    }

    static func format(_ addresses: [MailAddress]) -> String {
        addresses.map(format).joined(separator: ", ")
    }

    static func parse(_ raw: String) -> (addresses: [MailAddress], invalid: [String]) {
        var addresses: [MailAddress] = []
        var invalid: [String] = []
        for token in MailAddress.splitTopLevel(raw) {
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
}
#endif
