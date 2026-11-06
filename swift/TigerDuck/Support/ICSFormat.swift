import Foundation
import TigerDuckCore

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

    /// RFC 5545 §3.3.11: TEXT escapes a backslash, a semicolon and a comma, writes a line break as
    /// `\n`, and cannot hold the other control characters.
    nonisolated static func escaped(_ text: String) -> String {
        var out = ""
        for scalar in text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars {
            switch scalar {
            case "\\", ";", ",": out += "\\\(scalar)"
            case "\n", "\r": out += "\\n"
            case "\t": out.unicodeScalars.append(scalar)
            case _ where scalar.value < 0x20 || scalar.value == 0x7F: continue
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// RFC 5545 §3.1: a content line past 75 octets goes on after a CRLF and a space, and a fold
    /// must not split a UTF-8 sequence.
    nonisolated static func folded(_ line: String) -> String {
        var out = ""
        var octets = 0
        for scalar in line.unicodeScalars {
            let width = UTF8.width(scalar)
            if octets + width > 75 {
                out += "\r\n "
                octets = 1
            }
            out.unicodeScalars.append(scalar)
            octets += width
        }
        return out
    }
}
