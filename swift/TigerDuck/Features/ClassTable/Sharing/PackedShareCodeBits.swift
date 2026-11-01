import Foundation

nonisolated func binomial(_ n: Int, _ k: Int) -> Int {
    guard k >= 0, k <= n else { return 0 }
    var result = 1
    for i in 0..<min(k, n - k) { result = result * (n - i) / (i + 1) }
    return result
}

nonisolated func bitLength(_ value: Int) -> Int {
    Int.bitWidth - value.leadingZeroBitCount
}

nonisolated struct BitWriter {
    private(set) var bits: [Bool] = []

    mutating func put(_ value: Int, _ count: Int) {
        precondition(value >= 0 && (count >= Int.bitWidth - 1 || value < 1 << count), "\(value) in \(count) bits")
        for shift in (0..<count).reversed() { bits.append(value >> shift & 1 == 1) }
    }

    mutating func gamma(_ value: Int) {
        let count = bitLength(value)
        put(0, count - 1)
        put(value, count)
    }

    mutating func subset(_ indices: [Int], of n: Int, nonEmpty: Bool) {
        gamma(indices.count + (nonEmpty ? 0 : 1))
        let rank = indices.enumerated().reduce(0) { $0 + binomial($1.element, $1.offset + 1) }
        put(rank, bitLength(binomial(n, indices.count) - 1))
    }
}

nonisolated struct BitReader {
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
