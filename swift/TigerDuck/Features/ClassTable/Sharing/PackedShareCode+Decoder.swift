import Foundation
import TigerDuckCore

nonisolated extension PackedShareCode {
    enum Decoder {
        /// `code` is trimmed, upper-cased and starts with `prefix`.
        static func decode(_ code: String) throws -> ClassTableShareCode {
            let body = Array(code.utf8.dropFirst(prefix.utf8.count))
            if let version = body.first, (UInt8(ascii: "2")...UInt8(ascii: "9")).contains(version) {
                throw ClassTableShareCodeError.unknownVersion
            }
            guard body.first == packedVersion, let bits = PackedShareCode.bits(fromBase36: body.dropFirst()), bits.count >= 32 else {
                throw ClassTableShareCodeError.malformed
            }
            guard Array(bits[..<32]) == PackedShareCode.bits(checksum(Array(bits[32...])), count: 32) else {
                throw ClassTableShareCodeError.checksumMismatch
            }
            var r = BitReader(bits: bits)
            _ = try r.get(32)
            let sharedAt = epoch.addingTimeInterval(TimeInterval(try r.get(timeBits) * 60))
            let order = try readTerms(&r, sharedAt: sharedAt)
            guard order.allSatisfy({ ClassTableShareCode.isSemester($0[...]) }) else { throw ClassTableShareCodeError.malformed }
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
                var slot = (AcademicTerm.academicYear(at: sharedAt) - distance) * 3 + kind
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
                  !(order.allSatisfy { termKinds.contains(kind($0)) } && AcademicTerm.academicYear(at: sharedAt) - keys[0].year >= -1)
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
    }
}
