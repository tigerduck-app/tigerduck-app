#if os(iOS)
import Foundation

nonisolated enum MailHref {
    static let schemePattern = try! NSRegularExpression(pattern: "^([a-zA-Z][a-zA-Z0-9+.-]*):")

    static func sanitizeHref(_ href: String) -> String {
        let dropped = href.unicodeScalars.drop { $0.value <= 0x1F || $0 == " " }
        let filtered = dropped.filter { $0 != "\t" && $0 != "\r" && $0 != "\n" }
        return String(String.UnicodeScalarView(filtered))
    }

    static func toASCII(_ host: String) -> String {
        guard host.unicodeScalars.contains(where: { $0.value > 0x7F }) else { return host }
        var components = URLComponents()
        components.host = host
        guard let converted = components.url?.host, !converted.isEmpty else { return host }
        return converted.lowercased()
    }

    private struct BrowserURLParts {
        var host: String
        var port: Int?
        var path: String
        var query: String?
        var fragment: String?
    }

    private static let pathSafeBytes: Set<UInt8> = {
        var set = Set<UInt8>()
        for scalar in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@/?#".unicodeScalars {
            set.insert(UInt8(scalar.value))
        }
        return set
    }()

    static func canonicalHref(_ rawHref: String) -> String? {
        let href = sanitizeHref(rawHref).trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(href.startIndex..., in: href)
        guard let schemeMatch = schemePattern.firstMatch(in: href, range: range),
              let fullRange = Range(schemeMatch.range, in: href),
              let schemeRange = Range(schemeMatch.range(at: 1), in: href) else { return href }
        let scheme = href[schemeRange]
        let isHTTPS = ASCIIText.isASCIICaseInsensitiveEqual(scheme, "https")
        guard isHTTPS || ASCIIText.isASCIICaseInsensitiveEqual(scheme, "http") else { return href }
        let lowerScheme = isHTTPS ? "https" : "http"
        let rest = String(href[fullRange.upperBound...]).replacingOccurrences(of: "\\", with: "/")
        guard let parts = browserURLParts(rest) else { return nil }
        var result = "\(lowerScheme)://\(parts.host)"
        let defaultPort = isHTTPS ? 443 : 80
        if let port = parts.port, port != defaultPort { result += ":\(port)" }
        result += canonicalPathComponent(parts.path.isEmpty ? "/" : parts.path)
        if let query = parts.query { result += "?" + canonicalPathComponent(query) }
        if let fragment = parts.fragment { result += "#" + canonicalPathComponent(fragment) }
        return result
    }

    private static func browserURLParts(_ rest: String) -> BrowserURLParts? {
        let scalars = rest.unicodeScalars
        var start = scalars.startIndex
        while start < scalars.endIndex, scalars[start] == "/" {
            start = scalars.index(after: start)
        }
        var end = scalars.endIndex
        var cursor = start
        while cursor < scalars.endIndex {
            let c = scalars[cursor]
            if c == "/" || c == "?" || c == "#" {
                end = cursor
                break
            }
            cursor = scalars.index(after: cursor)
        }
        let authority = scalars[start..<end]
        var afterUserinfo = authority
        if let lastAt = authority.lastIndex(of: "@") {
            afterUserinfo = authority[authority.index(after: lastAt)...]
        }
        var host = afterUserinfo
        var portString = ""
        var hasPort = false
        if afterUserinfo.first == "[" {
            if let closing = afterUserinfo.firstIndex(of: "]") {
                host = afterUserinfo[afterUserinfo.startIndex...closing]
                let afterBracket = afterUserinfo[afterUserinfo.index(after: closing)...]
                if afterBracket.first == ":" {
                    hasPort = true
                    portString = String(afterBracket[afterBracket.index(after: afterBracket.startIndex)...])
                }
            }
        } else if let colon = afterUserinfo.firstIndex(of: ":") {
            host = afterUserinfo[afterUserinfo.startIndex..<colon]
            hasPort = true
            portString = String(afterUserinfo[afterUserinfo.index(after: colon)...])
        }
        guard !host.isEmpty else { return nil }
        let normalizedHost = toASCII(MailSchoolDomain.normalizedDomain(String(host)))
        var port: Int?
        if hasPort {
            guard !portString.isEmpty,
                  portString.unicodeScalars.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }),
                  let value = Int(portString) else { return nil }
            port = value
        }
        let tail = String(rest[end...])
        var pathPart = tail
        var fragment: String?
        if let hash = pathPart.firstIndex(of: "#") {
            fragment = String(pathPart[pathPart.index(after: hash)...])
            pathPart = String(pathPart[..<hash])
        }
        var query: String?
        if let question = pathPart.firstIndex(of: "?") {
            query = String(pathPart[pathPart.index(after: question)...])
            pathPart = String(pathPart[..<question])
        }
        return BrowserURLParts(host: normalizedHost, port: port, path: pathPart, query: query, fragment: fragment)
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
            || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
            || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "F"))
    }

    private static func hexDigitUppercased(_ byte: UInt8) -> UInt8 {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f")) ? byte - 0x20 : byte
    }

    private static func canonicalPathComponent(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        let bytes = Array(raw.utf8)
        var result = ""
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "%"), index + 2 < bytes.count, isHexDigit(bytes[index + 1]), isHexDigit(bytes[index + 2]) {
                result += "%"
                result.unicodeScalars.append(Unicode.Scalar(hexDigitUppercased(bytes[index + 1])))
                result.unicodeScalars.append(Unicode.Scalar(hexDigitUppercased(bytes[index + 2])))
                index += 3
                continue
            }
            if pathSafeBytes.contains(byte) {
                result.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                result += String(format: "%%%02X", byte)
            }
            index += 1
        }
        return result
    }
}
#endif
