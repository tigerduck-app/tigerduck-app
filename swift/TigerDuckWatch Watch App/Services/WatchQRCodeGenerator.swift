import Foundation

/// Pure-Swift QR Code matrix generator (ISO/IEC 18004, Model 2).
///
/// CoreImage's `CIFilter.qrCodeGenerator()` is unavailable on watchOS, so we
/// can't reuse the phone's renderer. This file produces the boolean module
/// matrix; the caller renders it (we render to a `UIImage` via CoreGraphics
/// in `LibraryQRViewModel.makeQRImage`).
///
/// Scope: byte (8-bit) mode, ECC levels L/M/Q/H, versions 1–40. No Kanji /
/// numeric / alphanumeric mode-switching — the library API payload is
/// arbitrary bytes so byte mode is fine.
///
/// Algorithm follows Project Nayuki's QR-Code-generator reference
/// implementation (MIT). Cross-checked against the ISO QR matrix examples.

// MARK: - Public API

public struct WatchQRMatrix: Equatable, Sendable {
    public let size: Int
    private let modules: [Bool]

    fileprivate init(size: Int, modules: [Bool]) {
        precondition(modules.count == size * size, "module count must equal size²")
        self.size = size
        self.modules = modules
    }

    public func module(x: Int, y: Int) -> Bool {
        guard x >= 0, x < size, y >= 0, y < size else { return false }
        return modules[y * size + x]
    }
}

public enum WatchQRECC: Int, Sendable {
    case low = 0
    case medium = 1
    case quartile = 2
    case high = 3

    fileprivate var formatBits: Int {
        switch self {
        case .low: return 0b01
        case .medium: return 0b00
        case .quartile: return 0b11
        case .high: return 0b10
        }
    }
}

public enum WatchQRCodeGenerator {
    public static func encode(_ text: String, ecc: WatchQRECC = .medium) -> WatchQRMatrix? {
        let bytes = Array(text.utf8)
        return encode(bytes: bytes, ecc: ecc)
    }

    public static func encode(bytes: [UInt8], ecc: WatchQRECC = .medium) -> WatchQRMatrix? {
        // Pick smallest version (1–40) whose byte-mode capacity fits the data.
        for version in 1...40 {
            let bitsNeeded = 4 + characterCountBits(version: version) + bytes.count * 8
            let capacity = numDataCodewords(version: version, ecc: ecc) * 8
            if bitsNeeded <= capacity {
                return Encoder(version: version, ecc: ecc, data: bytes).encode()
            }
        }
        return nil
    }
}

// MARK: - Internal encoder

private final class Encoder {
    let version: Int
    let ecc: WatchQRECC
    let data: [UInt8]
    let size: Int

    /// `nil` means "no module placed yet" — used by the function-pattern
    /// reservation pass so the data-snake placement can skip those cells.
    /// At the end we compress to `[Bool]` for the public matrix.
    var grid: [[Bool?]]

    init(version: Int, ecc: WatchQRECC, data: [UInt8]) {
        self.version = version
        self.ecc = ecc
        self.data = data
        self.size = version * 4 + 17
        self.grid = Array(repeating: Array(repeating: nil, count: size), count: size)
    }

    func encode() -> WatchQRMatrix {
        drawFunctionPatterns()
        let dataCodewords = buildDataCodewords()
        let allCodewords = addEcc(dataCodewords)
        drawCodewords(allCodewords)
        applyBestMask()
        return materializeMatrix()
    }

    // MARK: Function patterns (finders, separators, timing, alignment, dark module, reserved format/version)

    private func drawFunctionPatterns() {
        // Timing patterns
        for i in 0..<size {
            setFunc(x: 6, y: i, dark: i % 2 == 0)
            setFunc(x: i, y: 6, dark: i % 2 == 0)
        }
        // Finder patterns at (0,0), (size-7,0), (0,size-7)
        drawFinder(centerX: 3, centerY: 3)
        drawFinder(centerX: size - 4, centerY: 3)
        drawFinder(centerX: 3, centerY: size - 4)
        // Alignment patterns
        let alignPositions = alignmentPatternPositions(version: version)
        let count = alignPositions.count
        for i in 0..<count {
            for j in 0..<count {
                // Skip the three corners where finder patterns live.
                if (i == 0 && j == 0) || (i == 0 && j == count - 1) || (i == count - 1 && j == 0) { continue }
                drawAlignment(centerX: alignPositions[i], centerY: alignPositions[j])
            }
        }
        // Reserve format-info area (filled with zeros now; final bits drawn after masking).
        drawFormatBits(mask: 0)
        // Reserve version-info area for v7+.
        drawVersion()
    }

    private func drawFinder(centerX: Int, centerY: Int) {
        for dy in -4...4 {
            for dx in -4...4 {
                let dist = max(abs(dx), abs(dy))
                let x = centerX + dx, y = centerY + dy
                if x < 0 || x >= size || y < 0 || y >= size { continue }
                setFunc(x: x, y: y, dark: dist != 2 && dist != 4)
            }
        }
    }

    private func drawAlignment(centerX: Int, centerY: Int) {
        for dy in -2...2 {
            for dx in -2...2 {
                setFunc(x: centerX + dx, y: centerY + dy, dark: max(abs(dx), abs(dy)) != 1)
            }
        }
    }

    private func drawFormatBits(mask: Int) {
        let data = (ecc.formatBits << 3) | mask  // 5 bits
        var rem = data
        for _ in 0..<10 {
            rem = (rem << 1) ^ ((rem >> 9) * 0x537)
        }
        let bits = ((data << 10) | rem) ^ 0x5412  // 15 bits XOR mask

        // First copy
        for i in 0...5 { setFunc(x: 8, y: i, dark: getBit(bits, i)) }
        setFunc(x: 8, y: 7, dark: getBit(bits, 6))
        setFunc(x: 8, y: 8, dark: getBit(bits, 7))
        setFunc(x: 7, y: 8, dark: getBit(bits, 8))
        for i in 9..<15 { setFunc(x: 14 - i, y: 8, dark: getBit(bits, i)) }

        // Second copy
        for i in 0..<8 { setFunc(x: size - 1 - i, y: 8, dark: getBit(bits, i)) }
        for i in 8..<15 { setFunc(x: 8, y: size - 15 + i, dark: getBit(bits, i)) }
        setFunc(x: 8, y: size - 8, dark: true)  // Dark module
    }

    private func drawVersion() {
        guard version >= 7 else { return }
        var rem = version
        for _ in 0..<12 {
            rem = (rem << 1) ^ ((rem >> 11) * 0x1F25)
        }
        let bits = (version << 12) | rem  // 18 bits

        for i in 0..<18 {
            let dark = getBit(bits, i)
            let a = size - 11 + i % 3
            let b = i / 3
            setFunc(x: a, y: b, dark: dark)
            setFunc(x: b, y: a, dark: dark)
        }
    }

    private func setFunc(x: Int, y: Int, dark: Bool) {
        if x < 0 || x >= size || y < 0 || y >= size { return }
        grid[y][x] = dark
    }

    // MARK: Data codewords

    private func buildDataCodewords() -> [UInt8] {
        let dataCapacityBits = numDataCodewords(version: version, ecc: ecc) * 8
        var bits = BitBuffer()
        // Mode indicator: 0100 = byte mode
        bits.append(value: 0b0100, length: 4)
        bits.append(value: data.count, length: characterCountBits(version: version))
        for byte in data {
            bits.append(value: Int(byte), length: 8)
        }
        // Terminator + byte alignment
        let remaining = dataCapacityBits - bits.count
        bits.append(value: 0, length: min(4, remaining))
        bits.append(value: 0, length: (8 - bits.count % 8) % 8)
        // Padding 0xEC, 0x11 alternating
        var pad = 0xEC
        while bits.count < dataCapacityBits {
            bits.append(value: pad, length: 8)
            pad = (pad == 0xEC) ? 0x11 : 0xEC
        }
        return bits.bytes
    }

    // MARK: Reed-Solomon ECC + interleaving

    private func addEcc(_ data: [UInt8]) -> [UInt8] {
        let numBlocks = numErrorCorrectionBlocks(version: version, ecc: ecc)
        let blockEccLen = eccCodewordsPerBlock(version: version, ecc: ecc)
        let rawCodewords = numRawDataModules(version: version) / 8
        let numShortBlocks = numBlocks - rawCodewords % numBlocks
        let shortBlockLen = rawCodewords / numBlocks
        let generator = reedSolomonGenerator(degree: blockEccLen)

        // Split data + compute ECC per block
        var blocks: [[UInt8]] = []
        var k = 0
        for i in 0..<numBlocks {
            let dataLen = shortBlockLen - blockEccLen + (i < numShortBlocks ? 0 : 1)
            let dataChunk = Array(data[k..<(k + dataLen)])
            k += dataLen
            let ecc = reedSolomonRemainder(data: dataChunk, generator: generator)
            var block = dataChunk
            if i < numShortBlocks { block.append(0) }  // placeholder for interleaving
            block.append(contentsOf: ecc)
            blocks.append(block)
        }

        // Interleave columns: first all data column 0, then column 1, ... then ECC.
        var result: [UInt8] = []
        let maxLen = blocks.map { $0.count }.max() ?? 0
        for col in 0..<maxLen {
            for (bi, block) in blocks.enumerated() {
                // Skip the placeholder slot in short blocks at the data-tail column.
                if col == shortBlockLen - blockEccLen && bi < numShortBlocks { continue }
                if col < block.count { result.append(block[col]) }
            }
        }
        return result
    }

    private func reedSolomonGenerator(degree: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: degree)
        result[degree - 1] = 1
        var root: UInt8 = 1
        for _ in 0..<degree {
            for j in 0..<degree {
                result[j] = gfMul(result[j], root)
                if j + 1 < degree {
                    result[j] ^= result[j + 1]
                }
            }
            root = gfMul(root, 0x02)
        }
        return result
    }

    private func reedSolomonRemainder(data: [UInt8], generator: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: generator.count)
        for b in data {
            let factor = b ^ result[0]
            result.removeFirst()
            result.append(0)
            for i in 0..<generator.count {
                result[i] ^= gfMul(generator[i], factor)
            }
        }
        return result
    }

    private func gfMul(_ x: UInt8, _ y: UInt8) -> UInt8 {
        var z: UInt8 = 0
        for i in stride(from: 7, through: 0, by: -1) {
            z = (z << 1) ^ ((z >> 7) * 0x1D)
            z ^= ((y >> i) & 1) * x
        }
        return z
    }

    // MARK: Codeword placement (snake) + masking + scoring

    private func drawCodewords(_ codewords: [UInt8]) {
        var i = 0
        let total = codewords.count * 8
        var right = size - 1
        while right >= 1 {
            if right == 6 { right = 5 }
            for vert in 0..<size {
                for j in 0..<2 {
                    let x = right - j
                    let upward = ((right + 1) & 2) == 0
                    let y = upward ? size - 1 - vert : vert
                    if grid[y][x] == nil && i < total {
                        let bit = ((Int(codewords[i >> 3]) >> (7 - (i & 7))) & 1) != 0
                        grid[y][x] = bit
                        i += 1
                    }
                }
            }
            right -= 2
        }
    }

    private func applyBestMask() {
        var bestMask = 0
        var bestPenalty = Int.max
        var bestSnapshot: [[Bool?]] = []
        for m in 0..<8 {
            applyMask(m)
            drawFormatBits(mask: m)
            let p = penaltyScore()
            if p < bestPenalty {
                bestPenalty = p
                bestMask = m
                bestSnapshot = grid
            }
            applyMask(m)  // unapply (XOR is involution)
        }
        grid = bestSnapshot
        _ = bestMask  // already baked into bestSnapshot via drawFormatBits
    }

    private func applyMask(_ mask: Int) {
        for y in 0..<size {
            for x in 0..<size {
                guard let cell = grid[y][x] else { continue }
                // Skip function-pattern cells (we used `nil` for unset cells before
                // function patterns were placed, but function patterns also yield
                // non-nil values — we need a separate "is function" mask).
                if isFunctionModule(x: x, y: y) { continue }
                let invert: Bool
                switch mask {
                case 0: invert = (x + y) % 2 == 0
                case 1: invert = y % 2 == 0
                case 2: invert = x % 3 == 0
                case 3: invert = (x + y) % 3 == 0
                case 4: invert = (x / 3 + y / 2) % 2 == 0
                case 5: invert = (x * y) % 2 + (x * y) % 3 == 0
                case 6: invert = ((x * y) % 2 + (x * y) % 3) % 2 == 0
                case 7: invert = ((x + y) % 2 + (x * y) % 3) % 2 == 0
                default: invert = false
                }
                if invert { grid[y][x] = !cell }
            }
        }
    }

    private func isFunctionModule(x: Int, y: Int) -> Bool {
        // Recompute by structural test rather than tracking a separate "function" mask.
        // Finder + separator
        if (x <= 8 && y <= 8) ||
            (x >= size - 8 && y <= 8) ||
            (x <= 8 && y >= size - 8) { return true }
        // Timing patterns
        if x == 6 || y == 6 { return true }
        // Version info (v7+)
        if version >= 7 {
            if x >= size - 11 && x <= size - 9 && y <= 5 { return true }
            if y >= size - 11 && y <= size - 9 && x <= 5 { return true }
        }
        // Alignment patterns
        let alignPositions = alignmentPatternPositions(version: version)
        let cnt = alignPositions.count
        for i in 0..<cnt {
            for j in 0..<cnt {
                if (i == 0 && j == 0) || (i == 0 && j == cnt - 1) || (i == cnt - 1 && j == 0) { continue }
                let cx = alignPositions[i], cy = alignPositions[j]
                if abs(x - cx) <= 2 && abs(y - cy) <= 2 { return true }
            }
        }
        return false
    }

    private func penaltyScore() -> Int {
        var result = 0
        // Rule 1: runs of 5+ same-color modules
        for y in 0..<size {
            var runLen = 0
            var runColor: Bool? = nil
            for x in 0..<size {
                let c = grid[y][x] ?? false
                if c == runColor {
                    runLen += 1
                    if runLen == 5 { result += 3 }
                    else if runLen > 5 { result += 1 }
                } else {
                    runColor = c
                    runLen = 1
                }
            }
        }
        for x in 0..<size {
            var runLen = 0
            var runColor: Bool? = nil
            for y in 0..<size {
                let c = grid[y][x] ?? false
                if c == runColor {
                    runLen += 1
                    if runLen == 5 { result += 3 }
                    else if runLen > 5 { result += 1 }
                } else {
                    runColor = c
                    runLen = 1
                }
            }
        }
        // Rule 2: 2×2 blocks of same color
        for y in 0..<size - 1 {
            for x in 0..<size - 1 {
                let c = grid[y][x] ?? false
                if (grid[y][x + 1] ?? false) == c &&
                    (grid[y + 1][x] ?? false) == c &&
                    (grid[y + 1][x + 1] ?? false) == c {
                    result += 3
                }
            }
        }
        // Rule 3: finder-like patterns 1:1:3:1:1 with 4-module run on either side
        for y in 0..<size {
            for x in 0..<size - 10 {
                let pattern: [Bool] = (0..<11).map { (grid[y][x + $0] ?? false) }
                if matchesFinderRule3(pattern) { result += 40 }
            }
        }
        for x in 0..<size {
            for y in 0..<size - 10 {
                let pattern: [Bool] = (0..<11).map { (grid[y + $0][x] ?? false) }
                if matchesFinderRule3(pattern) { result += 40 }
            }
        }
        // Rule 4: proportion of dark modules
        var dark = 0
        for y in 0..<size {
            for x in 0..<size {
                if grid[y][x] ?? false { dark += 1 }
            }
        }
        let total = size * size
        let percent = (dark * 100 + total / 2) / total
        let k = (abs(percent - 50) + 4) / 5  // floor(|pct-50|/5)
        result += k * 10
        return result
    }

    private func matchesFinderRule3(_ p: [Bool]) -> Bool {
        // Pattern: D-L-D-D-D-L-D where the dark center is 3 modules wide and there's
        // a 4-module light run on one side. QR spec rule N3.
        let a: [Bool] = [true, false, true, true, true, false, true, false, false, false, false]
        let b: [Bool] = [false, false, false, false, true, false, true, true, true, false, true]
        return p == a || p == b
    }

    private func materializeMatrix() -> WatchQRMatrix {
        var flat = [Bool](repeating: false, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                flat[y * size + x] = grid[y][x] ?? false
            }
        }
        return WatchQRMatrix(size: size, modules: flat)
    }

    // MARK: Lookup tables (per ISO/IEC 18004:2015 tables)

    private func numRawDataModules(version: Int) -> Int {
        var result = (16 * version + 128) * version + 64
        if version >= 2 {
            let numAlign = version / 7 + 2
            result -= (25 * numAlign - 10) * numAlign - 55
            if version >= 7 { result -= 36 }
        }
        return result
    }

    private func numDataCodewords(version: Int, ecc: WatchQRECC) -> Int {
        return numRawDataModules(version: version) / 8 -
            eccCodewordsPerBlock(version: version, ecc: ecc) *
            numErrorCorrectionBlocks(version: version, ecc: ecc)
    }

    private func eccCodewordsPerBlock(version: Int, ecc: WatchQRECC) -> Int {
        return QRTables.eccCodewords[ecc.rawValue][version]
    }

    private func numErrorCorrectionBlocks(version: Int, ecc: WatchQRECC) -> Int {
        return QRTables.numBlocks[ecc.rawValue][version]
    }

    private func alignmentPatternPositions(version: Int) -> [Int] {
        if version == 1 { return [] }
        let numAlign = version / 7 + 2
        let step: Int
        if version == 32 {
            step = 26
        } else {
            step = (version * 4 + numAlign * 2 + 1) / (numAlign * 2 - 2) * 2
        }
        var result = [Int]()
        var pos = size - 7
        for _ in 0..<(numAlign - 1) {
            result.insert(pos, at: 0)
            pos -= step
        }
        result.insert(6, at: 0)
        return result
    }

    private func characterCountBits(version: Int) -> Int {
        return version <= 9 ? 8 : 16
    }
}

// MARK: - File-scope helpers (shared with capacity check in `WatchQRCodeGenerator.encode`)

private func characterCountBits(version: Int) -> Int {
    return version <= 9 ? 8 : 16
}

private func numRawDataModules(version: Int) -> Int {
    var result = (16 * version + 128) * version + 64
    if version >= 2 {
        let numAlign = version / 7 + 2
        result -= (25 * numAlign - 10) * numAlign - 55
        if version >= 7 { result -= 36 }
    }
    return result
}

private func numDataCodewords(version: Int, ecc: WatchQRECC) -> Int {
    return numRawDataModules(version: version) / 8 -
        QRTables.eccCodewords[ecc.rawValue][version] *
        QRTables.numBlocks[ecc.rawValue][version]
}

private func getBit(_ x: Int, _ i: Int) -> Bool {
    return ((x >> i) & 1) != 0
}

// MARK: - Lookup tables (ISO/IEC 18004:2015)

private enum QRTables {
    /// ECC codewords per block, indexed by `[ecc.rawValue][version]`. Index 0
    /// in the inner array is a `-1` placeholder so `version` (1-40) maps directly.
    static let eccCodewords: [[Int]] = [
        // L
        [-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
        // M
        [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
        // Q
        [-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
        // H
        [-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    ]

    /// Number of error-correction blocks, indexed by `[ecc.rawValue][version]`.
    static let numBlocks: [[Int]] = [
        // L
        [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
        // M
        [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
        // Q
        [-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
        // H
        [-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
    ]
}

// MARK: - Bit buffer

private struct BitBuffer {
    private(set) var bytes: [UInt8] = []
    private(set) var count = 0  // bit count

    mutating func append(value: Int, length: Int) {
        precondition(length >= 0 && length <= 32)
        for i in stride(from: length - 1, through: 0, by: -1) {
            let bit = (value >> i) & 1
            if count % 8 == 0 { bytes.append(0) }
            bytes[count / 8] |= UInt8(bit << (7 - count % 8))
            count += 1
        }
    }
}
