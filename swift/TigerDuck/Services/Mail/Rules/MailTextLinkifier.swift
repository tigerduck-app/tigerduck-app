#if os(iOS)
import Foundation

/// Text-only mail in the formatted view: URLs become links. The view routes every tap
/// through the link confirmation (§6.3), never straight to the browser.
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
