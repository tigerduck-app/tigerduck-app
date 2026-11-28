import Foundation

/// A raster image written into a mail as a `data:` address, which `MailHTMLSanitizer` keeps and
/// `MailBodyImage` previews.
nonisolated enum MailDataImage {
    private static let allowedPattern = try! NSRegularExpression(
        pattern: "^data:image/(png|jpeg|gif|webp)[;,]",
        options: .caseInsensitive
    )

    static func isAllowed(_ source: String) -> Bool {
        let range = NSRange(source.startIndex..., in: source)
        return allowedPattern.firstMatch(in: source, options: [], range: range) != nil
    }

    /// The payload is percent-decoded to bytes, then base64-decoded when marked `;base64`, as the
    /// Fetch standard's `data:` URL processor and so WebKit do.
    static func bytes(_ source: String) -> Data? {
        guard isAllowed(source), let comma = source.firstIndex(of: ",") else { return nil }
        let bytes = percentDecodedBytes(source[source.index(after: comma)...])
        guard source[..<comma].lowercased().hasSuffix(";base64") else { return bytes }
        return Data(base64Encoded: bytes, options: .ignoreUnknownCharacters)
    }

    private static func percentDecodedBytes(_ text: Substring) -> Data {
        let input = Array(text.utf8)
        var output = Data(capacity: input.count)
        var index = 0
        while index < input.count {
            if input[index] == UInt8(ascii: "%"), index + 2 < input.count,
               let high = Character(Unicode.Scalar(input[index + 1])).hexDigitValue,
               let low = Character(Unicode.Scalar(input[index + 2])).hexDigitValue {
                output.append(UInt8(high << 4 | low))
                index += 3
            } else {
                output.append(input[index])
                index += 1
            }
        }
        return output
    }
}
