#if os(iOS)
import Foundation

nonisolated enum MailSchoolDomain {
    static func normalizedDomain(_ raw: String) -> String {
        var domain = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while domain.hasSuffix(".") { domain.removeLast() }
        return domain
    }

    static func isSchoolDomain(_ raw: String) -> Bool {
        isSchoolDomain(raw, config: MailServerConfig.effective)
    }

    static func isSchoolDomain(_ raw: String, config: MailServerConfig) -> Bool {
        config.isOwnDomain(normalizedDomain(raw))
    }

    static func domain(ofAddress address: String) -> String {
        guard let at = address.lastIndex(of: "@") else { return "" }
        return normalizedDomain(String(address[address.index(after: at)...]))
    }

    static var schoolMailDomain: String { MailServerConfig.effective.addressDomain }

    private static let maxDomainTypoEdits = 2

    /// RFC 5321 §4.5.5: a delivery status notification is sent with the null reverse-path, which
    /// the receiving server records as `Return-Path: <>`.
    /// See docs/decisions/0013-mail-bounce-detection.md.
    static func isBounce(returnPath: String?) -> Bool {
        guard let returnPath else { return false }
        return returnPath.filter { !$0.isWhitespace } == "<>"
    }

    static func isMistypedSchoolMailDomain(_ domain: String, config: MailServerConfig = .effective) -> Bool {
        let host = MailHref.toASCII(normalizedDomain(domain))
        let mailDomain = config.addressDomain
        guard !host.isEmpty, !isSchoolDomain(host, config: config) else { return false }
        guard abs(host.count - mailDomain.count) <= maxDomainTypoEdits else { return false }
        return editDistance(host, mailDomain) <= maxDomainTypoEdits
    }

    static func mentionsMistypedSchoolAddress(_ text: String, config: MailServerConfig = .effective) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return MailLinkCheck.emailPattern.matches(in: text, range: range).contains { match in
            guard let matchRange = Range(match.range, in: text) else { return false }
            return isMistypedSchoolMailDomain(domain(ofAddress: String(text[matchRange])), config: config)
        }
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        let left = Array(a), right = Array(b)
        guard !left.isEmpty else { return right.count }
        guard !right.isEmpty else { return left.count }
        var previous = Array(0...right.count)
        var current = [Int](repeating: 0, count: right.count + 1)
        for i in 1...left.count {
            current[0] = i
            for j in 1...right.count {
                let substitution = previous[j - 1] + (left[i - 1] == right[j - 1] ? 0 : 1)
                current[j] = min(current[j - 1] + 1, previous[j] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[right.count]
    }
}
#endif
