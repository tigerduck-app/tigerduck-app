#if os(iOS)
import Foundation

nonisolated enum MailTextLinkifier {
    static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return result
        }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            guard let url = match.url,
                  let stringRange = Range(match.range, in: text),
                  let attributedRange = Range(stringRange, in: result) else { continue }
            result[attributedRange].link = url
        }
        return result
    }
}
#endif
