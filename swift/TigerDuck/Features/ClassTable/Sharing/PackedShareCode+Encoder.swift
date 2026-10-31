import Foundation
import TigerDuckCore

nonisolated extension PackedShareCode {
    enum Encoder {
        /// `terms` as `ClassTableShareCode.encode` keeps them: distinct, each holding distinct course codes of NTUST's
        /// shape. Only the newest 24 terms are written, which only sharing every term reaches; past
        /// any other limit there is no code.
        static func encode(studentId: String, sharedAt: Date, terms: [Term]) -> String? {
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
            let distance = AcademicTerm.academicYear(at: sharedAt) - year(order[0])
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
    }
}
