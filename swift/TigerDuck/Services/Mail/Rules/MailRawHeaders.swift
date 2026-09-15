#if os(iOS)
import Foundation

/// Header lookup on a raw RFC 822 message, for the one field SwiftMail's envelope
/// parsing drops (Reply-To). Unfolds continuation lines and RFC 2047-decodes the value.
nonisolated enum MailRawHeaders {
    static func value(named name: String, in raw: Data) -> String? {
        let separator = raw.range(of: Data("\r\n\r\n".utf8)) ?? raw.range(of: Data("\n\n".utf8))
        let headerData = separator.map { raw.subdata(in: raw.startIndex..<$0.lowerBound) } ?? raw
        let text = String(data: headerData, encoding: .utf8) ?? String(data: headerData, encoding: .isoLatin1) ?? ""
        let unfolded = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n[ \t]+", with: " ", options: .regularExpression)
        let prefix = name.lowercased() + ":"
        for line in unfolded.components(separatedBy: "\n") where line.lowercased().hasPrefix(prefix) {
            return RFC2047.decode(String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
#endif
