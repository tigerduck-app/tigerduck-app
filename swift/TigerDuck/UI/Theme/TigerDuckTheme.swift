import SwiftUI
import os

enum TigerDuckTheme {
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum CornerRadius {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 18
        static let xl: CGFloat = 24
    }

    enum Typography {
        static let largeTitle = Font.largeTitle.bold()
        static let title = Font.title2.bold()
        static let headline = Font.headline
        static let body = Font.body
        static let caption = Font.caption
        static let caption2 = Font.caption2
    }

    /// Status and grade tints. The light shades are darker versions of the dark page's pastels,
    /// dark enough to read on their own tinted badge fill over the light cards.
    enum Tint {
        static let green = adaptive(light: 0x196F3D, dark: 0x2ECC71)
        static let blue = adaptive(light: 0x216794, dark: 0x3498DB)
        static let yellow = adaptive(light: 0x785F00, dark: 0xF7DC6F)
        static let coral = adaptive(light: 0xAF3427, dark: 0xFF6B6B)
        static let red = adaptive(light: 0xAF3427, dark: 0xE74C3C)
        static let grey = adaptive(light: 0x576565, dark: 0x95A5A6)
        static let skyBlue = adaptive(light: 0x1F618D, dark: 0x85C1E9)
        static let teal = adaptive(light: 0x0C6D67, dark: 0x4ECDC4)
        static let cyan = adaptive(light: 0x1B6984, dark: 0x45B7D1)
        static let orange = adaptive(light: 0x9C4900, dark: 0xE67E22)
        static let purple = adaptive(light: 0x824B99, dark: 0x9B59B6)

        private static func adaptive(light: UInt, dark: UInt) -> Color {
            Color.adaptive(light: Color(hex: light), dark: Color(hex: dark))
        }
    }

    nonisolated static let coursePaletteHexes: [UInt32] = [
        0xFF6B6B,
        0x4ECDC4,
        0x45B7D1,
        0xF39C12,
        0xDDA0DD,
        0x2ECC71,
        0xE74C3C,
        0x3498DB,
        0xF7DC6F,
        0x9B59B6,
        0x1ABC9C,
        0xE67E22,
        0x85C1E9,
        0xD35400,
        0x27AE60,
        0xC0392B,
        0x8E44AD,
        0x16A085,
        0xF1C40F,
        0x2980B9,
    ]

    static let courseColors: [Color] = coursePaletteHexes.map { Color(hex: UInt($0)) }

    static func courseColorHex(for courseNo: String) -> String {
        String(format: "#%06X", assignedHex(for: courseNo))
    }

    private static var store: CourseColorStore { .shared }

    static var courseColorMap: [String: UInt32] {
        store.state.snapshot()
    }

    static func ensureAssignments(courseNos: [String]) {
        store.ensureAssignments(courseNos: courseNos, palette: coursePaletteHexes)
    }

    static func courseColor(for courseNo: String) -> Color {
        Color(hex: UInt(assignedHex(for: courseNo)))
    }

    static func assignedHex(for courseNo: String) -> UInt32 {
        store.hex(for: courseNo, palette: coursePaletteHexes)
    }

    static func paletteIndex(for courseNo: String) -> Int? {
        let hex = assignedHex(for: courseNo)
        return coursePaletteHexes.firstIndex(of: hex)
    }

    @discardableResult
    static func setColor(hex: UInt32, for courseNo: String) -> [String: UInt32] {
        store.apply(.pick(hex & 0xFFFFFF, courseNo: courseNo), palette: coursePaletteHexes)
    }

    @discardableResult
    static func applyColors(_ colors: [(courseNo: String, hex: UInt32)]) -> Bool {
        store.applyColors(colors, palette: coursePaletteHexes)
    }

    nonisolated static func assigning(
        _ hex: UInt32,
        to courseNo: String,
        in map: [String: UInt32],
        palette: [UInt32] = coursePaletteHexes
    ) -> (map: [String: UInt32], changed: [String: UInt32]) {
        ColorState.assigning(hex & 0xFFFFFF, to: courseNo, in: map, palette: palette)
    }

    static func snapshot() -> [String: UInt32] {
        store.state.snapshot()
    }

    static func reload() {
        store.reload()
    }

    static func reassignAll(courseNos: [String]) {
        store.apply(.reassignAll(courseNos: courseNos), palette: coursePaletteHexes)
    }
}

final class ColorState: @unchecked Sendable {
    /// nil until the map file is read. Behind the lock screen the file exists but cannot be opened
    /// (`completeFileProtectionUnlessOpen`), and an empty map then would hand out fresh colours and
    private nonisolated(unsafe) var map: [String: UInt32]?
    private nonisolated(unsafe) var unreadableReads = 0
    private nonisolated(unsafe) var lastCountedRead: Date?
    private let lock = OSAllocatedUnfairLock()
    private let load: @Sendable () -> [String: UInt32]?
    private let save: @Sendable ([String: UInt32]) -> Void
    private let notePick: @Sendable (String) -> Void
    private let forgetPicks: @Sendable () -> Void
    private let protectedDataAvailable: @Sendable () -> Bool
    private let now: @Sendable () -> Date

    nonisolated static let unreadableReadLimit = 3
    nonisolated static let unreadableReadSpacing: TimeInterval = 10

    /// How many times the map was saved, which `CourseColorStore` turns into its revision.
    nonisolated(unsafe) private(set) var saves = 0

    init(
        load: @escaping @Sendable () -> [String: UInt32]?,
        save: @escaping @Sendable ([String: UInt32]) -> Void,
        notePick: @escaping @Sendable (String) -> Void,
        forgetPicks: @escaping @Sendable () -> Void,
        protectedDataAvailable: @escaping @Sendable () -> Bool = ColorState.isProtectedDataAvailable,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.load = load
        self.save = save
        self.notePick = notePick
        self.forgetPicks = forgetPicks
        self.protectedDataAvailable = protectedDataAvailable
        self.now = now
        self.map = read()
    }

    /// Every colour read runs on the main actor, where `UIApplication` answers. A read from
    /// anywhere else answers false, which counts nothing toward giving up on the file.
    nonisolated static func isProtectedDataAvailable() -> Bool {
        #if os(iOS)
        guard Thread.isMainThread else { return false }
        return MainActor.assumeIsolated { UIApplication.shared.isProtectedDataAvailable }
        #else
        return true
        #endif
    }

    private func loadedMap() -> [String: UInt32]? {
        if map == nil { map = read() }
        return map
    }

    private nonisolated func read() -> [String: UInt32]? {
        if let stored = load() {
            unreadableReads = 0
            return stored
        }
        guard protectedDataAvailable() else { return nil }
        let now = now()
        if lastCountedRead.map({ now.timeIntervalSince($0) >= Self.unreadableReadSpacing }) ?? true {
            lastCountedRead = now
            unreadableReads += 1
            if unreadableReads == Self.unreadableReadLimit {
                AppLogger.persistence.error("Course colour map unreadable with protected data available, starting from an empty map")
            }
        }
        return unreadableReads >= Self.unreadableReadLimit ? [:] : nil
    }

    func snapshot() -> [String: UInt32] {
        lock.withLock { loadedMap() ?? [:] }
    }

    func hex(for courseNo: String, palette: [UInt32]) -> UInt32 {
        lock.withLock {
            if let h = loadedMap()?[courseNo] { return h }
            return palette[Self.hashIndex(for: courseNo, paletteCount: palette.count)]
        }
    }

    func ensureAssignments(courseNos: [String], palette: [UInt32]) {
        let didMutate: Bool = lock.withLock {
            guard var map = loadedMap() else { return false }
            var mutated = false
            var seenHexes: Set<UInt32> = []
            for courseNo in map.keys.sorted() {
                guard let hex = map[courseNo] else { continue }
                if seenHexes.insert(hex).inserted { continue }
                map.removeValue(forKey: courseNo)
                mutated = true
            }
            var used = Set(map.values)
            for courseNo in courseNos.sorted() where map[courseNo] == nil {
                let assigned = Self.pickUnusedHex(seed: courseNo, used: used, palette: palette)
                map[courseNo] = assigned
                used.insert(assigned)
                mutated = true
            }
            self.map = map
            return mutated
        }
        if didMutate { persist() }
    }

    func setColor(hex newHex: UInt32, for courseNo: String, palette: [UInt32]) -> [String: UInt32] {
        let changed: [String: UInt32] = lock.withLock {
            guard let map = loadedMap() else { return [:] }
            let result = Self.assigning(newHex, to: courseNo, in: map, palette: palette)
            self.map = result.map
            return result.changed
        }
        if !changed.isEmpty {
            persist()
            notePick(courseNo)
        }
        return changed
    }

    func applyColors(_ colors: [(courseNo: String, hex: UInt32)], palette: [UInt32]) -> Bool {
        let didMutate: Bool = lock.withLock {
            guard let current = loadedMap() else { return false }
            var updated = current
            for (courseNo, hex) in colors {
                updated = Self.assigning(hex & 0xFFFFFF, to: courseNo, in: updated, palette: palette).map
            }
            guard updated != current else { return false }
            map = updated
            return true
        }
        if didMutate { persist() }
        return didMutate
    }

    nonisolated static func assigning(
        _ newHex: UInt32,
        to courseNo: String,
        in map: [String: UInt32],
        palette: [UInt32]
    ) -> (map: [String: UInt32], changed: [String: UInt32]) {
        guard map[courseNo] != newHex else { return (map, [:]) }
        var updated = map
        let displaced = map.compactMap { entry -> String? in
            entry.key != courseNo && entry.value == newHex ? entry.key : nil
        }.sorted()
        updated[courseNo] = newHex
        for d in displaced { updated.removeValue(forKey: d) }
        var used = Set(updated.values)
        for d in displaced {
            let assigned = pickUnusedHex(seed: d, used: used, palette: palette)
            updated[d] = assigned
            used.insert(assigned)
        }
        return (updated, updated.filter { map[$0.key] != $0.value })
    }

    func reload() {
        lock.withLock { map = read() }
    }

    func reassignAll(courseNos: [String], palette: [UInt32]) {
        let reassigned: Bool = lock.withLock {
            guard loadedMap() != nil else { return false }
            let shuffled = palette.shuffled()
            var fresh: [String: UInt32] = [:]
            var used: Set<UInt32> = []
            for courseNo in courseNos.sorted() {
                let assigned = Self.pickUnusedHex(seed: courseNo, used: used, palette: shuffled)
                fresh[courseNo] = assigned
                used.insert(assigned)
            }
            map = fresh
            return true
        }
        guard reassigned else { return }
        persist()
        forgetPicks()
    }

    private func persist() {
        guard let snapshot = lock.withLock({ map }) else { return }
        save(snapshot)
        lock.withLock {
            unreadableReads = 0
            saves &+= 1
        }
    }

    private nonisolated static func pickUnusedHex(seed: String, used: Set<UInt32>, palette: [UInt32]) -> UInt32 {
        let start = hashIndex(for: seed, paletteCount: palette.count)
        for offset in 0..<palette.count {
            let candidate = palette[(start + offset) % palette.count]
            if !used.contains(candidate) { return candidate }
        }
        var state: UInt32 = 2_166_136_261
        for c in seed.unicodeScalars { state = (state ^ c.value) &* 16_777_619 }
        for _ in 0..<256 {
            state = state &* 1_664_525 &+ 1_013_904_223
            let candidate = state >> 8
            if !used.contains(candidate) { return candidate }
        }
        return palette[start] ^ UInt32(truncatingIfNeeded: used.count)
    }

    private nonisolated static func hashIndex(for courseNo: String, paletteCount: Int) -> Int {
        var h = 0
        for c in courseNo.unicodeScalars {
            h = (h &* 31 &+ Int(c.value)) & 0x7FFFFFFF
        }
        return h % paletteCount
    }
}
