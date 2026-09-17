#if os(iOS)
import Foundation

/// Charset rules from design doc Appendix A.5 — identical on Android.
nonisolated enum MailCharset {
    /// The encoding A.5 prescribes for a MIME charset label; nil when unknown.
    static func encoding(forLabel label: String?) -> String.Encoding? {
        guard let raw = label?.trimmingCharacters(in: CharacterSet(charactersIn: "\" \t")).lowercased(),
              !raw.isEmpty else { return nil }
        switch raw {
        case "big5", "big-5", "cn-big5", "x-x-big5":
            return cf(.big5_HKSCS_1999)
        case "gb2312", "gb_2312-80", "gbk", "x-gbk":
            return cf(.GB_18030_2000)
        default:
            let encoding = CFStringConvertIANACharSetNameToEncoding(raw as CFString)
            guard encoding != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
        }
    }

    /// The labelled charset, else strict UTF-8, then Big5-HKSCS, then ISO-8859-1
    /// (which never fails, so no byte is lost).
    ///
    /// A *labelled* part is decoded leniently, matching Android, where `String(bytes, charset)`
    /// substitutes U+FFFD for a malformed byte and always returns. `String(data:encoding:)` is
    /// strict and returns nil instead, which used to send a correctly labelled body with one
    /// truncated byte — an everyday shape in real mail — down the guess chain below, where
    /// Big5-HKSCS accepts almost any byte string and the whole message rendered as mojibake.
    /// The guess chain is for parts with no usable label, not for a label the server gave us.
    static func decode(_ data: Data, label: String?) -> String {
        if let encoding = encoding(forLabel: label) {
            if let text = String(data: data, encoding: encoding) { return text }
            if let text = lossilyDecoded(data, encoding: encoding) { return text }
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: cf(.big5_HKSCS_1999)) { return text }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// `encoding` with malformed bytes replaced rather than rejected. Foundation offers no
    /// lossy `String(data:encoding:)`, but its encoding *detector* does the same substitution
    /// when it is restricted to a single candidate and allowed to convert lossily. Returns nil
    /// only if even that fails, leaving the caller's fallback chain in charge.
    private static func lossilyDecoded(_ data: Data, encoding: String.Encoding) -> String? {
        var converted: NSString?
        var usedLossyConversion: ObjCBool = false
        let options: [StringEncodingDetectionOptionsKey: Any] = [
            .suggestedEncodingsKey: [encoding.rawValue],
            .useOnlySuggestedEncodingsKey: true,
            .allowLossyKey: true,
        ]
        guard NSString.stringEncoding(for: data, encodingOptions: options,
                                      convertedString: &converted,
                                      usedLossyConversion: &usedLossyConversion) != 0 else { return nil }
        return converted as String?
    }

    private static func cf(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
    }
}

/// RFC 2047 encoded-word decoding with the A.5 charset rules. Lenient: whitespace between
/// adjacent encoded words is dropped, and a malformed word is left as written.
nonisolated enum RFC2047 {
    private static let pattern = try! NSRegularExpression(pattern: #"=\?([^?\s]+)\?([bBqQ])\?([^?\s]*)\?="#)

    static func decode(_ header: String) -> String {
        let ns = header as NSString
        let matches = pattern.matches(in: header, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return header }
        var result = ""
        var cursor = 0
        var previousWasDecoded = false
        for match in matches {
            let between = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if !(previousWasDecoded && between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                result += between
            }
            let charset = ns.substring(with: match.range(at: 1)).split(separator: "*").first.map(String.init)
            let mode = ns.substring(with: match.range(at: 2)).uppercased()
            let text = ns.substring(with: match.range(at: 3))
            let bytes = mode == "B" ? Data(base64Encoded: padded(text)) : qDecode(text)
            if let bytes {
                result += MailCharset.decode(bytes, label: charset)
                previousWasDecoded = true
            } else {
                result += ns.substring(with: match.range)
                previousWasDecoded = false
            }
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    private static func padded(_ base64: String) -> String {
        let remainder = base64.count % 4
        return remainder == 0 ? base64 : base64 + String(repeating: "=", count: 4 - remainder)
    }

    private static func qDecode(_ text: String) -> Data? {
        var bytes: [UInt8] = []
        var iterator = Array(text.utf8).makeIterator()
        while let byte = iterator.next() {
            switch byte {
            case UInt8(ascii: "_"):
                bytes.append(0x20)
            case UInt8(ascii: "="):
                guard let high = iterator.next(), let low = iterator.next(),
                      let hex = String(bytes: [high, low], encoding: .ascii),
                      let value = UInt8(hex, radix: 16) else { return nil }
                bytes.append(value)
            default:
                bytes.append(byte)
            }
        }
        return Data(bytes)
    }
}
#endif
