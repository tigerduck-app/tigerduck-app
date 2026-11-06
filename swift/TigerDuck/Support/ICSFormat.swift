import Foundation
import TigerDuckCore

/// The text forms of iCalendar (RFC 5545).
enum ICSFormat {
    static let date = formatter("yyyyMMdd", timeZone: TaipeiTime.timeZone)
    static let dateTime = formatter("yyyyMMdd'T'HHmmss", timeZone: TaipeiTime.timeZone)
    static let utcDateTime = formatter("yyyyMMdd'T'HHmmss'Z'", timeZone: TimeZone(identifier: "UTC"))

    static func formatter(_ format: String, timeZone: TimeZone?) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = format
        f.timeZone = timeZone
        return f
    }

    /// Unescape ICS TEXT-typed values per RFC 5545:
    /// `\,` → `,`, `\;` → `;`, `\n` / `\N` → newline, `\\` → `\`.
    /// Without this, raw escape sequences leak into the UI as
    /// `Final Exam\, MA1`.
    nonisolated static func unescaped(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        var iter = raw.makeIterator()
        while let ch = iter.next() {
            if ch == "\\" {
                guard let next = iter.next() else {
                    out.append(ch)
                    break
                }
                switch next {
                case "n", "N": out.append("\n")
                case ",": out.append(",")
                case ";": out.append(";")
                case "\\": out.append("\\")
                default:
                    out.append("\\")
                    out.append(next)
                }
            } else {
                out.append(ch)
            }
        }
        return out
    }
}
