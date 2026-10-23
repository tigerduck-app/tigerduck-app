import Foundation
import zlib

/// Our share code's packed layout, version 1: the student ID, share time, terms and course codes
/// packed into bits and written in Base36 after `prefix`, so a code stays short, in QR
/// alphanumeric mode, and reads offline. The Android app and the share page write and read the
/// same codes. Every class table has one code, so anything an encoder would write otherwise is
/// malformed. See docs/decisions/0023-class-table-share-code.md.
nonisolated extension ClassTableShareCode {
    private static let packedVersion = UInt8(ascii: "1")
    private static let base36Digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
    private static let maxStudentIdLength = 16
    private static let maxTerms = 24
    private static let maxCourses = 64
    /// 2024-01-01 00:00 in Taipei. A share time is the minutes since, in 24 bits: up to 2055-11-24.
    private static let epoch = Date(timeIntervalSince1970: 1_704_038_400)
    private static let timeBits = 24
    /// A regular term list's last characters, and the student ID letters with the shortest codes.
    private static let termKinds = Array("12H".utf8)
    private static let idLetters = Array("BMD".utf8)
    /// The heads in NTUST's public course lists for 1121 to 1151 and 114H, frozen for version 1.
    private static let knownHeads = (
        "3N 3NG 3T 3TG AC AD AI AS AT BA BB BE CC CE CH CI CS CT CX DT EC EE EN EO EP ES ET FB FE FL FN GD "
            + "GE HC IB IC IM IS MA MB ME MG MI PA PE RD SD SI TB TC TE TM TU TX VE ZA"
    ).split(separator: " ").map(String.init)
    /// Two letters, then `3` and two letters, then `3` and one letter.
    private static let headValueCount = 676 * 2 + 26

    private static let taipei: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .gmt
        return calendar
    }()

    // MARK: Encoding

    /// `terms` as `encode` keeps them: distinct, each holding distinct course codes of NTUST's
    /// shape. Only the newest 24 terms are written, which only sharing every term reaches; past
    /// any other limit there is no code.
    static func encodePacked(studentId: String, sharedAt: Date, terms: [Term]) -> String? {
        let seconds = sharedAt.timeIntervalSince(epoch)
        guard studentId.utf8.count <= maxStudentIdLength,
              seconds >= 0, seconds < Double(60 << timeBits) else { return nil }
        let order = Array(terms.sorted { termKey($0.semester) > termKey($1.semester) }.prefix(maxTerms))
        guard !order.isEmpty, order.allSatisfy({ $0.courseNos.count <= maxCourses }) else { return nil }

        var w = BitWriter()
        w.put(Int(seconds / 60), timeBits)
        writeTerms(order.map(\.semester), sharedAt: sharedAt, into: &w)
        writeStudentId(studentId, oldestYear: order.map { year($0.semester) }.min() ?? 0, into: &w)

        let byTerm = order.map { term in
            Dictionary(grouping: term.courseNos.compactMap(split), by: { $0.head }).mapValues { $0.map { $0.tail }.sorted() }
        }
        let used = Set(byTerm.flatMap(\.keys))
        let known = used.compactMap { knownHeads.firstIndex(of: $0) }.sorted()
        let unknown = used.filter { !knownHeads.contains($0) }.map(headValue).sorted()
        w.subset(known, of: knownHeads.count, nonEmpty: false)
        w.gamma(unknown.count + 1)
        for value in unknown { w.put(value, 11) }
        let heads = known.map { knownHeads[$0] } + unknown.map(headText)

        if order.count > 1, heads.count > 1 {
            for head in heads {
                w.subset(byTerm.indices.filter { byTerm[$0][head] != nil }, of: order.count, nonEmpty: true)
            }
        }
        for groups in byTerm {
            let present = heads.compactMap { head in groups[head].map { (head, $0) } }
            for (_, tails) in present { w.gamma(tails.count) }
            for (_, tails) in present {
                var level: Int?
                for tail in tails { level = writeTail(tail, level: level, into: &w) }
            }
        }

        let data = w.bits + Array(repeating: false, count: padding(32 + w.bits.count))
        return prefix + String(UnicodeScalar(packedVersion)) + base36(bits(checksum(data), count: 32) + data)
    }

    private static func writeTerms(_ order: [String], sharedAt: Date, into w: inout BitWriter) {
        let distance = academicYear(sharedAt) - year(order[0])
        let isRegular = order.allSatisfy { termKinds.contains(kind($0)) } && distance >= -1
        w.put(isRegular ? 0 : 1, 1)
        w.gamma(order.count)
        if isRegular {
            w.gamma([0: 1, -1: 2, 1: 3][distance] ?? distance + 2)
            w.put(termKinds.firstIndex(of: kind(order[0])) ?? 0, 2)
            for (newer, older) in zip(order, order.dropFirst()) { w.gamma(slot(newer) - slot(older)) }
        } else {
            for term in order {
                w.put(year(term), 10)
                w.put(digitValue(kind(term)) ?? 0, 6)
            }
        }
    }

    private static func writeStudentId(_ studentId: String, oldestYear: Int, into w: inout BitWriter) {
        if let parts = ntustStudentId(studentId), oldestYear >= parts.year {
            w.put(0, 1)
            if let index = idLetters.firstIndex(of: parts.letter) {
                w.put((1 << (index + 1)) - 2, index + 1)
            } else {
                w.put((1 << idLetters.count) - 1, idLetters.count)
                w.put(Int(parts.letter - UInt8(ascii: "A")), 5)
            }
            w.gamma(oldestYear - parts.year + 1)
            w.put(parts.serial, 17)
        } else {
            w.put(1, 1)
            w.gamma(studentId.utf8.count)
            for character in studentId.utf8 { w.put(digitValue(character) ?? 0, 6) }
        }
    }

    /// Returns the level the head's next leveled tail is written against.
    private static func writeTail(_ tail: String, level: Int?, into w: inout BitWriter) -> Int? {
        switch shape(of: tail) {
        case let .leveled(tailLevel, number, isSeven, serial):
            w.put(0, 1)
            if let level, tailLevel == level {
                w.put(0, 1)
            } else if let level, tailLevel == level + 1 {
                w.put(0b10, 2)
            } else {
                if level != nil { w.put(0b11, 2) }
                writeLevel(tailLevel, into: &w)
            }
            w.put(number, 10)
            w.put(isSeven ? 1 : 0, 1)
            w.gamma(serial)
            return tailLevel
        case let .lettered(number, isB, serial):
            w.put(0b100, 3)
            w.put(number, 10)
            w.put(isB ? 1 : 0, 1)
            w.gamma(serial)
        case let .general(number, serial):
            w.put(0b101, 3)
            w.put(number, 10)
            w.gamma(serial)
        case let .short(number, serial):
            w.put(0b110, 3)
            w.put(number, 10)
            w.gamma(serial)
        case let .digits(number):
            w.put(0b1110, 4)
            w.put(number, 24)
        case .other:
            w.put(0b1111, 4)
            w.put(tail.utf8.count - 6, 1)
            for character in tail.utf8 { w.put(digitValue(character) ?? 0, 6) }
        }
        return level
    }

    private static func writeLevel(_ level: Int, into w: inout BitWriter) {
        switch level {
        case 1...4:
            w.put(0, 1)
            w.put(level - 1, 2)
        case 5:
            w.put(0b10, 2)
        default:
            w.put(0b11, 2)
            w.put(level, 4)
        }
    }

    // MARK: Decoding

    /// `code` is trimmed, upper-cased and starts with `prefix`.
    static func decodePacked(_ code: String) throws -> ClassTableShareCode {
        let body = Array(code.utf8.dropFirst(prefix.utf8.count))
        if let version = body.first, (UInt8(ascii: "2")...UInt8(ascii: "9")).contains(version) {
            throw ClassTableShareCodeError.unknownVersion
        }
        guard body.first == packedVersion, let bits = Self.bits(fromBase36: body.dropFirst()), bits.count >= 32 else {
            throw ClassTableShareCodeError.malformed
        }
        guard Array(bits[..<32]) == self.bits(checksum(Array(bits[32...])), count: 32) else {
            throw ClassTableShareCodeError.checksumMismatch
        }
        var r = BitReader(bits: bits)
        _ = try r.get(32)
        let sharedAt = epoch.addingTimeInterval(TimeInterval(try r.get(timeBits) * 60))
        let order = try readTerms(&r, sharedAt: sharedAt)
        let studentId = try readStudentId(&r, oldestYear: order.map(year).min() ?? 0)
        let heads = try readHeads(&r)

        var membership = heads.map { _ in Set(order.indices) }
        if order.count > 1, heads.count > 1 {
            membership = try heads.map { _ in Set(try r.subset(of: order.count, nonEmpty: true)) }
        }
        var seen = Set<Int>()
        var terms: [Term] = []
        for (index, semester) in order.enumerated() {
            let present = heads.indices.filter { membership[$0].contains(index) }
            guard !present.isEmpty else { throw ClassTableShareCodeError.malformed }
            let counts = try present.map { _ in try r.gamma(limit: maxCourses) }
            guard counts.reduce(0, +) <= maxCourses else { throw ClassTableShareCodeError.malformed }
            var courseNos: [String] = []
            for (head, count) in zip(present.map { heads[$0] }, counts) {
                courseNos += try readCourses(&r, head: head, count: count)
            }
            seen.formUnion(present)
            terms.append(Term(semester: semester, courseNos: courseNos.sorted()))
        }
        guard seen.count == heads.count, bits.count - r.used == padding(r.used), !bits[r.used...].contains(true) else {
            throw ClassTableShareCodeError.malformed
        }
        return ClassTableShareCode(format: .tigerDuck, studentId: studentId, sharedAt: sharedAt, terms: terms)
    }

    private static func readTerms(_ r: inout BitReader, sharedAt: Date) throws -> [String] {
        let isRegular = try r.get(1) == 0
        let count = try r.gamma(limit: maxTerms)
        if isRegular {
            let distanceCode = try r.gamma()
            let distance = [1: 0, 2: -1, 3: 1][distanceCode] ?? distanceCode - 2
            let kind = try r.get(2)
            guard kind < termKinds.count else { throw ClassTableShareCodeError.malformed }
            var slot = (academicYear(sharedAt) - distance) * 3 + kind
            var slots = [slot]
            for _ in 1..<count {
                slot -= try r.gamma()
                slots.append(slot)
            }
            guard slot >= 0 else { throw ClassTableShareCodeError.malformed }
            return slots.map { padded($0 / 3, 3) + String(UnicodeScalar(termKinds[$0 % 3])) }
        }
        var keys: [(year: Int, kind: Int)] = []
        for _ in 0..<count {
            let key = (year: try r.get(10), kind: try r.get(6))
            guard key.year <= 999, key.kind < 36 else { throw ClassTableShareCodeError.malformed }
            keys.append(key)
        }
        let order = keys.map { padded($0.year, 3) + String(UnicodeScalar(base36Digits[$0.kind])) }
        guard zip(keys, keys.dropFirst()).allSatisfy({ $0 > $1 }),
              !(order.allSatisfy { termKinds.contains(kind($0)) } && academicYear(sharedAt) - keys[0].year >= -1)
        else { throw ClassTableShareCodeError.malformed }
        return order
    }

    private static func readStudentId(_ r: inout BitReader, oldestYear: Int) throws -> String {
        if try r.get(1) == 0 {
            var index = 0
            while index < idLetters.count, try r.get(1) == 1 { index += 1 }
            var letter = idLetters.first ?? 0
            if index < idLetters.count {
                letter = idLetters[index]
            } else {
                let value = try r.get(5)
                letter = UInt8(ascii: "A") + UInt8(min(value, 31))
                guard value <= 25, !idLetters.contains(letter) else { throw ClassTableShareCodeError.malformed }
            }
            let year = oldestYear - (try r.gamma() - 1)
            let serial = try r.get(17)
            guard year >= 0, serial <= 99_999 else { throw ClassTableShareCodeError.malformed }
            return String(UnicodeScalar(letter)) + padded(year, 3) + padded(serial, 5)
        }
        let length = try r.gamma(limit: maxStudentIdLength)
        let values = try (0..<length).map { _ in try r.get(6) }
        guard values.allSatisfy({ $0 < 36 }) else { throw ClassTableShareCodeError.malformed }
        let studentId = String(decoding: values.map { base36Digits[$0] }, as: UTF8.self)
        if let parts = ntustStudentId(studentId), oldestYear >= parts.year { throw ClassTableShareCodeError.malformed }
        return studentId
    }

    private static func readHeads(_ r: inout BitReader) throws -> [String] {
        let known = try r.subset(of: knownHeads.count, nonEmpty: false)
        let unknownCount = try r.gamma() - 1
        // A longer list than there are heads cannot be one of distinct heads.
        guard unknownCount <= headValueCount - knownHeads.count else { throw ClassTableShareCodeError.malformed }
        let unknown = try (0..<unknownCount).map { _ in try r.get(11) }
        guard unknown.allSatisfy({ $0 < headValueCount && !knownHeads.contains(headText($0)) }),
              zip(unknown, unknown.dropFirst()).allSatisfy({ $0 < $1 }),
              !(known.isEmpty && unknown.isEmpty)
        else { throw ClassTableShareCodeError.malformed }
        return known.map { knownHeads[$0] } + unknown.map(headText)
    }

    private static func readCourses(_ r: inout BitReader, head: String, count: Int) throws -> [String] {
        var courseNos: [String] = []
        var level: Int?
        var last: String?
        for _ in 0..<count {
            let (tail, nextLevel) = try readTail(&r, level: level)
            level = nextLevel
            if let last, !last.utf8.lexicographicallyPrecedes(tail.utf8) { throw ClassTableShareCodeError.malformed }
            last = tail
            // A head and tail the head rule splits otherwise, as 3N with G115701, are another course's.
            guard let parts = split(head + tail), parts.head == head, parts.tail == tail else {
                throw ClassTableShareCodeError.malformed
            }
            courseNos.append(head + tail)
        }
        return courseNos
    }

    private static func readTail(_ r: inout BitReader, level: Int?) throws -> (String, Int?) {
        if try r.get(1) == 0 {
            let tailLevel: Int
            if let level {
                if try r.get(1) == 0 {
                    tailLevel = level
                } else if try r.get(1) == 0 {
                    tailLevel = level + 1
                } else {
                    tailLevel = try readLevel(&r)
                    guard tailLevel != level, tailLevel != level + 1 else { throw ClassTableShareCodeError.malformed }
                }
            } else {
                tailLevel = try readLevel(&r)
            }
            let number = try r.get(10)
            guard tailLevel <= 9, number <= 999 else { throw ClassTableShareCodeError.malformed }
            let section = try r.get(1) == 0 ? "3" : "7"
            return (String(tailLevel) + padded(number, 3) + section + (try serial(&r)), tailLevel)
        }
        let code = try r.get(2)
        if code < 3 {
            let number = try r.get(10)
            guard number <= 999 else { throw ClassTableShareCodeError.malformed }
            let digits = padded(number, 3)
            switch code {
            case 0: return (digits + (try r.get(1) == 0 ? "A" : "B") + "0" + (try serial(&r)), level)
            case 1: return ("G" + digits + "3" + (try serial(&r)), level)
            default: return (digits + "7" + (try serial(&r)), level)
            }
        }
        let tail: String
        if try r.get(1) == 0 {
            let number = try r.get(24)
            guard number <= 9_999_999 else { throw ClassTableShareCodeError.malformed }
            tail = padded(number, 7)
            guard case .digits = shape(of: tail) else { throw ClassTableShareCodeError.malformed }
        } else {
            let length = 6 + (try r.get(1))
            let values = try (0..<length).map { _ in try r.get(6) }
            guard values.allSatisfy({ $0 < 36 }) else { throw ClassTableShareCodeError.malformed }
            tail = String(decoding: values.map { base36Digits[$0] }, as: UTF8.self)
            guard case .other = shape(of: tail) else { throw ClassTableShareCodeError.malformed }
        }
        return (tail, level)
    }

    private static func readLevel(_ r: inout BitReader) throws -> Int {
        if try r.get(1) == 0 { return try r.get(2) + 1 }
        if try r.get(1) == 0 { return 5 }
        let level = try r.get(4)
        guard level == 0 || (6...9).contains(level) else { throw ClassTableShareCodeError.malformed }
        return level
    }

    private static func serial(_ r: inout BitReader) throws -> String {
        padded(try r.gamma(limit: 99), 2)
    }

    // MARK: Shared rules

    /// A course code's tail shapes, in the order an encoder tries them; the last field is the
    /// section's serial, from 1.
    private enum Shape {
        case leveled(level: Int, number: Int, isSeven: Bool, serial: Int)
        case lettered(number: Int, isB: Bool, serial: Int)
        case general(number: Int, serial: Int)
        case short(number: Int, serial: Int)
        case digits(Int)
        case other
    }

    private static func shape(of tail: String) -> Shape {
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

    /// The head is the first that fits of `3` and two letters, two letters, or `3` and one letter
    /// (NTU and NTNU courses, such as `3N1004701`), as in `CourseSelectionService.isCourseNo`.
    private static func split(_ courseNo: String) -> (head: String, tail: String)? {
        guard let m = courseNo.wholeMatch(of: /(3[A-Z]{2}|[A-Z]{2}|3[A-Z])([A-Z0-9]{6,7})/) else { return nil }
        return (String(m.1), String(m.2))
    }

    private static func ntustStudentId(_ studentId: String) -> (letter: UInt8, year: Int, serial: Int)? {
        guard let m = studentId.wholeMatch(of: /([A-Z])([0-9]{3})([0-9]{5})/), let letter = m.1.utf8.first else {
            return nil
        }
        return (letter, number(m.2), number(m.3))
    }

    /// ASCII digits only, which every caller has matched.
    private static func number(_ digits: Substring) -> Int {
        digits.utf8.reduce(0) { $0 * 10 + Int($1) - Int(UInt8(ascii: "0")) }
    }

    private static func padded(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    private static func digitValue(_ character: UInt8) -> Int? {
        base36Digits.firstIndex(of: character)
    }

    private static func year(_ semester: String) -> Int { number(semester.prefix(3)) }

    private static func kind(_ semester: String) -> UInt8 { semester.utf8.last ?? 0 }

    private static func termKey(_ semester: String) -> (Int, Int) { (year(semester), digitValue(kind(semester)) ?? 0) }

    private static func slot(_ semester: String) -> Int {
        year(semester) * 3 + (termKinds.firstIndex(of: kind(semester)) ?? 0)
    }

    /// The ROC academic year in Taipei, which starts in August.
    private static func academicYear(_ date: Date) -> Int {
        let parts = taipei.dateComponents([.year, .month], from: date)
        return (parts.year ?? 0) - 1911 - ((parts.month ?? 0) < 8 ? 1 : 0)
    }

    private static func headValue(_ head: String) -> Int {
        let letters = head.utf8.map { Int($0) - Int(UInt8(ascii: "A")) }
        if letters.count == 2, head.first == "3" { return 676 * 2 + letters[1] }
        return (letters.count == 3 ? 676 : 0) + letters[letters.count - 2] * 26 + letters[letters.count - 1]
    }

    private static func headText(_ value: Int) -> String {
        func letter(_ index: Int) -> String { String(UnicodeScalar(UInt8(ascii: "A") + UInt8(index))) }
        if value >= 676 * 2 { return "3" + letter(value - 676 * 2) }
        return (value >= 676 ? "3" : "") + letter(value % 676 / 26) + letter(value % 26)
    }

    /// The zero bits that make the last Base36 group 31 bits, or a multiple of 5.
    private static func padding(_ count: Int) -> Int {
        let remainder = count % 31
        return remainder > 25 ? 31 - remainder : (5 - remainder % 5) % 5
    }

    /// zlib's CRC-32 of the prefix and version, then `data` zero-filled to whole bytes.
    private static func checksum(_ data: [Bool]) -> Int {
        var bytes = Array(prefix.utf8) + [packedVersion]
        for start in stride(from: 0, to: data.count, by: 8) {
            let byte = data[start..<min(start + 8, data.count)].enumerated()
                .reduce(UInt8(0)) { $1.element ? $0 | UInt8(0x80) >> $1.offset : $0 }
            bytes.append(byte)
        }
        return Int(crc32(0, bytes, uInt(bytes.count)))
    }

    private static func bits(_ value: Int, count: Int) -> [Bool] {
        (0..<count).reversed().map { value >> $0 & 1 == 1 }
    }

    /// Groups of 31 bits as 6 digits, and a last, shorter group of 5k bits as k digits.
    private static func base36(_ bits: [Bool]) -> String {
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

    /// Nil for a character outside `0-9A-Z` or a group too large for its bits.
    private static func bits(fromBase36 text: ArraySlice<UInt8>) -> [Bool]? {
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

nonisolated private func binomial(_ n: Int, _ k: Int) -> Int {
    guard k >= 0, k <= n else { return 0 }
    var result = 1
    for i in 0..<min(k, n - k) { result = result * (n - i) / (i + 1) }
    return result
}

nonisolated private func bitLength(_ value: Int) -> Int {
    Int.bitWidth - value.leadingZeroBitCount
}

nonisolated private struct BitWriter {
    private(set) var bits: [Bool] = []

    mutating func put(_ value: Int, _ count: Int) {
        precondition(value >= 0 && (count >= Int.bitWidth - 1 || value < 1 << count), "\(value) in \(count) bits")
        for shift in (0..<count).reversed() { bits.append(value >> shift & 1 == 1) }
    }

    /// Elias gamma: one zero fewer than the bits of `value`, which is 1 or more, then `value`.
    mutating func gamma(_ value: Int) {
        let count = bitLength(value)
        put(0, count - 1)
        put(value, count)
    }

    /// A sorted subset of `0..<n`: its size, then its rank among subsets of that size, the sum of
    /// C(index, position + 1) (the combinatorial number system).
    mutating func subset(_ indices: [Int], of n: Int, nonEmpty: Bool) {
        gamma(indices.count + (nonEmpty ? 0 : 1))
        let rank = indices.enumerated().reduce(0) { $0 + binomial($1.element, $1.offset + 1) }
        put(rank, bitLength(binomial(n, indices.count) - 1))
    }
}

nonisolated private struct BitReader {
    let bits: [Bool]
    private(set) var used = 0

    init(bits: [Bool]) {
        self.bits = bits
    }

    mutating func get(_ count: Int) throws -> Int {
        guard count <= bits.count - used else { throw ClassTableShareCodeError.malformed }
        let value = bits[used..<used + count].reduce(0) { $0 << 1 | ($1 ? 1 : 0) }
        used += count
        return value
    }

    /// Refused past `limit` or more than 32 leading zeros.
    mutating func gamma(limit: Int = 1 << 32) throws -> Int {
        var zeros = 0
        while try get(1) == 0 {
            zeros += 1
            guard zeros <= 32 else { throw ClassTableShareCodeError.malformed }
        }
        let value = 1 << zeros | (try get(zeros))
        guard value <= limit else { throw ClassTableShareCodeError.malformed }
        return value
    }

    mutating func subset(of n: Int, nonEmpty: Bool) throws -> [Int] {
        let count = try nonEmpty ? gamma(limit: n) : gamma(limit: n + 1) - 1
        let total = binomial(n, count)
        var rank = try get(bitLength(total - 1))
        guard rank < total else { throw ClassTableShareCodeError.malformed }
        var indices: [Int] = []
        for position in stride(from: count, through: 1, by: -1) {
            var index = position - 1
            while binomial(index + 1, position) <= rank { index += 1 }
            rank -= binomial(index, position)
            indices.append(index)
        }
        return indices.reversed()
    }
}
