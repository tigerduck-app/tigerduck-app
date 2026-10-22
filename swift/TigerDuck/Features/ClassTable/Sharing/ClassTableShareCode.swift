import Compression
import Foundation
import zlib

nonisolated struct ClassTableShareCode: Equatable, Sendable {
    enum Format: Equatable, Sendable {
        case tigerDuck
        case tat2
        case tat1
    }

    struct Term: Equatable, Sendable {
        let semester: String
        let courseNos: [String]
    }

    let format: Format
    let studentId: String?
    let sharedAt: Date?
    let terms: [Term]

    static let prefix = "HTTPS://TIGERDUCK.APP/T/"

    static func decode(_ text: String) throws -> ClassTableShareCode {
        let code = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if code.hasPrefix(prefix) { return try decodeTigerDuck(code) }
        if code.hasPrefix(tatPrefix) { return try decodeTAT(code) }
        throw ClassTableShareCodeError.unknownPrefix
    }

    static func encode(studentId: String, sharedAt: Date, terms: [Term]) -> String? {
        let id = studentId.uppercased()
        guard isUpperAlphanumerics(id[...]) else { return nil }
        var semesters = Set<String>()
        let kept = terms.compactMap { term -> Term? in
            let semester = term.semester.uppercased()
            let courseNos = Set(term.courseNos.map { $0.uppercased() }.filter { isCourseNo($0[...]) }).sorted()
            guard isSemester(semester[...]), !courseNos.isEmpty, semesters.insert(semester).inserted else {
                return nil
            }
            return Term(semester: semester, courseNos: courseNos)
        }
        let text = kept.map { $0.courseNos.joined(separator: ",") }.joined(separator: ";")
        guard !kept.isEmpty, let compressed = deflated(Array(text.utf8)) else { return nil }
        let fields = ["1", id, stamp(sharedAt), kept.map(\.semester).joined(separator: "-"), base32(compressed)]
        let body = prefix + fields.joined(separator: ".")
        return body + "." + checksum(of: body[...])
    }

    private static func decodeTigerDuck(_ code: String) throws -> ClassTableShareCode {
        let fields = code.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard fields[0] == "1" else {
            throw isDigits(fields[0]) ? ClassTableShareCodeError.unknownVersion : .malformed
        }
        guard isASCII(code[...]), fields.count == 6, let lastDot = code.lastIndex(of: ".") else {
            throw ClassTableShareCodeError.malformed
        }
        guard checksum(of: code[..<lastDot]) == fields[5] else { throw ClassTableShareCodeError.checksumMismatch }

        let semesters = fields[3].split(separator: "-", omittingEmptySubsequences: false)
        guard isUpperAlphanumerics(fields[1]),
              let sharedAt = date(fromStamp: fields[2]),
              semesters.allSatisfy(isSemester),
              Set(semesters).count == semesters.count
        else { throw ClassTableShareCodeError.malformed }

        let groups = try inflatedText(fromBase32: fields[4]).split(separator: ";", omittingEmptySubsequences: false)
        guard groups.count == semesters.count else { throw ClassTableShareCodeError.malformed }
        let terms = try zip(semesters, groups).map { semester, group in
            Term(
                semester: String(semester),
                courseNos: try checkedCourseNos(group.split(separator: ",", omittingEmptySubsequences: false))
            )
        }
        return ClassTableShareCode(format: .tigerDuck, studentId: String(fields[1]), sharedAt: sharedAt, terms: terms)
    }

    private static func stamp(_ date: Date) -> String {
        let parts = AppConstants.taipeiCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04ld%02ld%02ld%02ld%02ld",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0
        )
    }

    private static func date(fromStamp stamp: Substring) -> Date? {
        guard stamp.utf8.count == 12, isDigits(stamp) else { return nil }
        let digits = stamp.utf8.map { Int($0 - UInt8(ascii: "0")) }
        func number(_ range: Range<Int>) -> Int { digits[range].reduce(0) { $0 * 10 + $1 } }
        let parts = DateComponents(
            year: number(0..<4), month: number(4..<6), day: number(6..<8),
            hour: number(8..<10), minute: number(10..<12)
        )
        guard let date = AppConstants.taipeiCalendar.date(from: parts), Self.stamp(date) == stamp else { return nil }
        return date
    }

    static func isCourseNo(_ text: Substring) -> Bool {
        text.wholeMatch(of: /3?[A-Z]{2}[A-Z0-9]{6,7}/) != nil
    }

    static func isSemester(_ text: Substring) -> Bool {
        text.utf8.count == 4 && isDigits(text.prefix(3)) && isUpperAlphanumerics(text.suffix(1))
    }

    static func checkedCourseNos(_ items: [Substring]) throws -> [String] {
        guard !items.contains(where: \.isEmpty), Set(items).count == items.count else {
            throw ClassTableShareCodeError.malformed
        }
        if let bad = items.first(where: { !isCourseNo($0) }) {
            throw ClassTableShareCodeError.invalidCourseCode(String(bad))
        }
        return items.map(String.init)
    }

    static func isASCII(_ text: Substring) -> Bool {
        text.utf8.allSatisfy { $0 < 0x80 }
    }

    static func isDigits(_ text: Substring) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }

    static func isUpperAlphanumerics(_ text: Substring) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0)
        }
    }

    private static func checksum(of text: Substring) -> String {
        let bytes = Array(text.utf8)
        let crc = UInt32(truncatingIfNeeded: crc32(0, bytes, uInt(bytes.count)))
        return base32([24, 16, 8, 0].map { UInt8(truncatingIfNeeded: crc >> $0) })
    }

    private static let inflatedLimit = 65_536

    private static func deflated(_ bytes: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: bytes.count + 64)
        let count = compression_encode_buffer(&output, output.count, bytes, bytes.count, nil, COMPRESSION_ZLIB)
        return count > 0 ? Array(output.prefix(count)) : nil
    }

    private static func inflatedText(fromBase32 text: Substring) throws -> Substring {
        guard let compressed = base32Decoded(text), !compressed.isEmpty else {
            throw ClassTableShareCodeError.malformed
        }
        var output = [UInt8](repeating: 0, count: inflatedLimit)
        let count = compression_decode_buffer(
            &output, output.count, compressed, compressed.count, nil, COMPRESSION_ZLIB
        )
        guard count > 0, count < output.count, output.prefix(count).allSatisfy({ $0 < 0x80 }) else {
            throw ClassTableShareCodeError.malformed
        }
        return String(decoding: output.prefix(count), as: UTF8.self)[...]
    }

    private static let base32Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

    static func base32(_ bytes: [UInt8]) -> String {
        var output: [UInt8] = []
        var buffer = 0
        var bits = 0
        for byte in bytes {
            buffer = (buffer << 8 | Int(byte)) & 0xFFF
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(base32Alphabet[(buffer >> bits) & 31])
            }
        }
        if bits > 0 { output.append(base32Alphabet[(buffer << (5 - bits)) & 31]) }
        return String(decoding: output, as: UTF8.self)
    }

    static func base32Decoded(_ text: Substring) -> [UInt8]? {
        var output: [UInt8] = []
        var buffer = 0
        var bits = 0
        for character in text.utf8 {
            guard let value = base32Alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5 | value) & 0xFFF
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8(truncatingIfNeeded: buffer >> bits))
            }
        }
        guard bits < 5, buffer & ((1 << bits) - 1) == 0 else { return nil }
        return output
    }
}

nonisolated enum ClassTableShareCodeError: Error, Equatable, Sendable {
    case unknownPrefix
    case unknownVersion
    case malformed
    case checksumMismatch
    case invalidCourseCode(String)
}
