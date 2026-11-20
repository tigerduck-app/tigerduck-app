import Foundation
import zlib
import TigerDuckCore

/// Our share code's packed layout, version 1: the student ID, share time, terms and course codes
/// packed into bits and written in Base36 after `prefix`, so a code stays short, in QR
/// alphanumeric mode, and reads offline. The Android app and the share page write and read the
/// same codes. Every class table has one code, so anything an encoder would write otherwise is
/// malformed. See docs/decisions/0023-class-table-share-code.md.
nonisolated enum PackedShareCode {
    typealias Term = ClassTableShareCode.Term

    static let prefix = ClassTableShareCode.prefix
    static let packedVersion = UInt8(ascii: "1")
    static let base36Digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
    static let maxStudentIdLength = 16
    static let maxTerms = 24
    static let maxCourses = 64
    /// 2024-01-01 00:00 in Taipei. A share time is the minutes since, in 24 bits: up to 2055-11-24.
    static let epoch = Date(timeIntervalSince1970: 1_704_038_400)
    static let timeBits = 24
    /// A regular term list's last characters, and the student ID letters with the shortest codes.
    static let termKinds = Array("12H".utf8)
    static let idLetters = Array("BMD".utf8)
    /// The heads in NTUST's public course lists for 1121 to 1151 and 114H, frozen for version 1.
    static let knownHeads = (
        "3N 3NG 3T 3TG AC AD AI AS AT BA BB BE CC CE CH CI CS CT CX DT EC EE EN EO EP ES ET FB FE FL FN GD "
            + "GE HC IB IC IM IS MA MB ME MG MI PA PE RD SD SI TB TC TE TM TU TX VE ZA"
    ).split(separator: " ").map(String.init)
    /// Two letters, then `3` and two letters, then `3` and one letter.
    static let headValueCount = 676 * 2 + 26

    enum Shape {
        case leveled(level: Int, number: Int, isSeven: Bool, serial: Int)
        case lettered(number: Int, isB: Bool, serial: Int)
        case general(number: Int, serial: Int)
        case short(number: Int, serial: Int)
        case digits(Int)
        case other
    }

    static func shape(of tail: String) -> Shape {
        if let m = tail.wholeMatch(of: /([0-9])([0-9]{3})([37])([0-9]{2})/), number(m.4) >= 1 {
            return .leveled(level: number(m.1), number: number(m.2), isSeven: m.3 == "7", serial: number(m.4))
        }
        if let m = tail.wholeMatch(of: /([0-9]{3})([AB])0([0-9]{2})/), number(m.3) >= 1 {
            return .lettered(number: number(m.1), isB: m.2 == "B", serial: number(m.3))
        }
        if let m = tail.wholeMatch(of: /G([0-9]{3})3([0-9]{2})/), number(m.2) >= 1 {
            return .general(number: number(m.1), serial: number(m.2))
        }
        if let m = tail.wholeMatch(of: /([0-9]{3})7([0-9]{2})/), number(m.2) >= 1 {
            return .short(number: number(m.1), serial: number(m.2))
        }
        if tail.wholeMatch(of: /[0-9]{7}/) != nil { return .digits(number(tail[...])) }
        return .other
    }

    /// `3` heads are NTU and NTNU courses, such as `3N1004701`.
    static func split(_ courseNo: String) -> (head: String, tail: String)? {
        guard let m = courseNo.wholeMatch(of: /(3[A-Z]{2}|[A-Z]{2}|3[A-Z])([A-Z0-9]{6,7})/) else { return nil }
        return (String(m.1), String(m.2))
    }

    static func ntustStudentId(_ studentId: String) -> (letter: UInt8, year: Int, serial: Int)? {
        guard let m = studentId.wholeMatch(of: /([A-Z])([0-9]{3})([0-9]{5})/), let letter = m.1.utf8.first else {
            return nil
        }
        return (letter, number(m.2), number(m.3))
    }

    static func number(_ digits: Substring) -> Int {
        Int(digits) ?? 0
    }

    static func padded(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    static func digitValue(_ character: UInt8) -> Int? {
        base36Digits.firstIndex(of: character)
    }

    static func year(_ semester: String) -> Int { number(semester.prefix(3)) }

    static func kind(_ semester: String) -> UInt8 { semester.utf8.last ?? 0 }

    static func termKey(_ semester: String) -> (Int, Int) { (year(semester), digitValue(kind(semester)) ?? 0) }

    static func slot(_ semester: String) -> Int {
        year(semester) * 3 + (termKinds.firstIndex(of: kind(semester)) ?? 0)
    }

    static func headValue(_ head: String) -> Int {
        let letters = head.utf8.map { Int($0) - Int(UInt8(ascii: "A")) }
        if letters.count == 2, head.first == "3" { return 676 * 2 + letters[1] }
        return (letters.count == 3 ? 676 : 0) + letters[letters.count - 2] * 26 + letters[letters.count - 1]
    }

    static func headText(_ value: Int) -> String {
        func letter(_ index: Int) -> String { String(UnicodeScalar(UInt8(ascii: "A") + UInt8(index))) }
        if value >= 676 * 2 { return "3" + letter(value - 676 * 2) }
        return (value >= 676 ? "3" : "") + letter(value % 676 / 26) + letter(value % 26)
    }

    /// The zero bits that make the last Base36 group 31 bits, or a multiple of 5.
    static func padding(_ count: Int) -> Int {
        let remainder = count % 31
        return remainder > 25 ? 31 - remainder : (5 - remainder % 5) % 5
    }

    /// zlib's CRC-32 of the prefix and version, then `data` zero-filled to whole bytes.
    static func checksum(_ data: [Bool]) -> Int {
        var bytes = Array(prefix.utf8) + [packedVersion]
        for start in stride(from: 0, to: data.count, by: 8) {
            let byte = data[start..<min(start + 8, data.count)].enumerated()
                .reduce(UInt8(0)) { $1.element ? $0 | UInt8(0x80) >> $1.offset : $0 }
            bytes.append(byte)
        }
        return Int(crc32(0, bytes, uInt(bytes.count)))
    }

    static func bits(_ value: Int, count: Int) -> [Bool] {
        (0..<count).reversed().map { value >> $0 & 1 == 1 }
    }

    /// Groups of 31 bits as 6 digits, and a last, shorter group of 5k bits as k digits.
    static func base36(_ bits: [Bool]) -> String {
        var output: [UInt8] = []
        for start in stride(from: 0, to: bits.count, by: 31) {
            let group = bits[start..<min(start + 31, bits.count)]
            var value = group.reduce(0) { $0 << 1 | ($1 ? 1 : 0) }
            var digits = [UInt8](repeating: 0, count: group.count == 31 ? 6 : group.count / 5)
            for index in digits.indices.reversed() {
                digits[index] = base36Digits[value % 36]
                value /= 36
            }
            output += digits
        }
        return String(decoding: output, as: UTF8.self)
    }

    static func bits(fromBase36 text: ArraySlice<UInt8>) -> [Bool]? {
        var bits: [Bool] = []
        for start in stride(from: text.startIndex, to: text.endIndex, by: 6) {
            let chunk = text[start..<min(start + 6, text.endIndex)]
            var value = 0
            for character in chunk {
                guard let digit = digitValue(character) else { return nil }
                value = value * 36 + digit
            }
            let count = chunk.count == 6 ? 31 : 5 * chunk.count
            guard value < 1 << count else { return nil }
            bits += self.bits(value, count: count)
        }
        return bits
    }
}
