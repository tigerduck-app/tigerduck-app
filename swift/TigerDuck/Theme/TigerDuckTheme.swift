import SwiftUI
import os

enum TigerDuckTheme {
    // MARK: - Spacing
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: - Corner Radius
    enum CornerRadius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 18
        static let xl: CGFloat = 24
    }

    // MARK: - Font
    enum Typography {
        static let largeTitle = Font.largeTitle.bold()
        static let title = Font.title2.bold()
        static let headline = Font.headline
        static let body = Font.body
        static let caption = Font.caption
        static let caption2 = Font.caption2
    }

    // MARK: - Course Colors (20-color palette, high visual distinctness)
    /// Source-of-truth palette as 24-bit RGB integers. `courseColors` derives
    /// `Color` values from this list; the watch-sync encoder reads it via
    /// `courseColorHex(for:)` so its hex output stays in lockstep with what
    /// the phone renders.
    static let coursePaletteHexes: [UInt32] = [
        0xFF6B6B, // 珊瑚紅
        0x4ECDC4, // 青綠
        0x45B7D1, // 天藍
        0xF39C12, // 橘橙
        0xDDA0DD, // 梅紫
        0x2ECC71, // 翡翠綠
        0xE74C3C, // 磚紅
        0x3498DB, // 寶藍
        0xF7DC6F, // 金黃
        0x9B59B6, // 紫羅蘭
        0x1ABC9C, // 碧綠
        0xE67E22, // 南瓜橘
        0x85C1E9, // 淺藍
        0xD35400, // 焦橙
        0x27AE60, // 森林綠
        0xC0392B, // 酒紅
        0x8E44AD, // 深紫
        0x16A085, // 松綠
        0xF1C40F, // 向日葵黃
        0x2980B9, // 鈷藍
    ]

    static let courseColors: [Color] = coursePaletteHexes.map { Color(hex: UInt($0)) }

    /// "#RRGGBB" hex for the course's currently assigned color. Mirrors
    /// `courseColor(for:)` but returns the wire-format string used by
    /// `WatchPayloadEncoder`.
    static func courseColorHex(for courseNo: String) -> String {
        String(format: "#%06X", assignedHex(for: courseNo))
    }

    /// Lock-protected mutable state for the per-course color map.
    /// `ensureAssignments` runs from background sync while `setColor` runs on
    /// MainActor (settings UI); without synchronization the concurrent
    /// mutations race against SDCourse-driven reads on the render thread.
    private static let state = ColorState()

    /// Snapshot of the current courseNo → assigned hex map. Read by the
    /// widget snapshot writer / watch payload encoder; the snapshot stays
    /// consistent across `setColor` even when a displacement reassigns
    /// another course.
    static var courseColorMap: [String: UInt32] {
        state.snapshot()
    }

    /// Ensure every passed-in courseNo has a unique assigned color. New
    /// courses pick the first unused preset (starting at their hash index for
    /// stability); once the 20-color palette is exhausted, fresh random hex
    /// values fill in.
    static func ensureAssignments(courseNos: [String]) {
        state.ensureAssignments(courseNos: courseNos, palette: coursePaletteHexes)
    }

    static func courseColor(for courseNo: String) -> Color {
        Color(hex: UInt(assignedHex(for: courseNo)))
    }

    /// Resolved hex for this course. Falls back to the deterministic hash
    /// default if no entry has been assigned yet (callers should invoke
    /// `ensureAssignments` to persist).
    static func assignedHex(for courseNo: String) -> UInt32 {
        state.hex(for: courseNo, palette: coursePaletteHexes)
    }

    /// Palette index when the assigned color happens to match a preset, else
    /// `nil` (the course holds a fully custom hex). Drives the picker's
    /// "ringed preset" highlight.
    static func paletteIndex(for courseNo: String) -> Int? {
        let hex = assignedHex(for: courseNo)
        return coursePaletteHexes.firstIndex(of: hex)
    }

    /// Persist a user-picked color for this course. If another course
    /// currently holds the same hex, that other course is reassigned to the
    /// first unused preset (or a random distinct hex when all 20 are taken)
    /// so the uniqueness invariant survives the edit.
    static func setColor(hex: UInt32, for courseNo: String) {
        state.setColor(hex: hex & 0xFFFFFF, for: courseNo, palette: coursePaletteHexes)
    }

    static func snapshot() -> [String: UInt32] {
        state.snapshot()
    }

    /// Refresh the in-memory map from disk. Called when the underlying
    /// user-scoped data is swapped (e.g. logout/login).
    static func reload() {
        state.reload()
    }

    /// Clear every assignment and rebuild from scratch using the preset
    /// palette (falling back to random hex once exhausted). Powers the
    /// Settings "Reassign course colors" action.
    static func reassignAll(courseNos: [String]) {
        state.reassignAll(courseNos: courseNos, palette: coursePaletteHexes)
    }
}

/// Wraps the lock + state for `TigerDuckTheme`. Hidden behind a class so the
/// generic `OSAllocatedUnfairLock<T>` is not visible at the use sites (the
/// prior generic-in-static-let arrangement triggered the Swift type-checker's
/// complexity budget on the surrounding palette literal).
private final class ColorState: @unchecked Sendable {
    private nonisolated(unsafe) var map: [String: UInt32]
    private let lock = OSAllocatedUnfairLock()

    private static let hashMigrationKey = "color_hash_v2_migrated"

    init() {
        if !UserDefaults.standard.bool(forKey: Self.hashMigrationKey) {
            DataCache.shared.saveCourseColorMap([:])
            UserDefaults.standard.set(true, forKey: Self.hashMigrationKey)
        }
        self.map = DataCache.shared.loadCourseColorMap()
    }

    func snapshot() -> [String: UInt32] {
        lock.withLock { map }
    }

    /// Returns the assigned hex if one exists; otherwise falls back to the
    /// deterministic hash default so a course that hasn't gone through
    /// `ensureAssignments` yet still renders a sensible color.
    func hex(for courseNo: String, palette: [UInt32]) -> UInt32 {
        lock.withLock {
            if let h = map[courseNo] { return h }
            return palette[Self.hashIndex(for: courseNo, paletteCount: palette.count)]
        }
    }

    func ensureAssignments(courseNos: [String], palette: [UInt32]) {
        let didMutate: Bool = lock.withLock {
            var mutated = false
            // Repair duplicate hexes left over from the legacy migration
            // (the pre-uniqueness map could persist multiple courses on
            // the same palette index). Walk by sorted courseNo so the
            // keeper is deterministic, drop the rest from `map`, and let
            // the missing-assignment loop below pick fresh unique colors
            // for any of them still in the current roster.
            var seenHexes: Set<UInt32> = []
            for courseNo in map.keys.sorted() {
                guard let hex = map[courseNo] else { continue }
                if seenHexes.insert(hex).inserted { continue }
                map.removeValue(forKey: courseNo)
                mutated = true
            }
            var used = Set(map.values)
            // Stable order so an iteration over a fresh roster always assigns
            // colors the same way — important because the user might re-order
            // the array between calls.
            for courseNo in courseNos.sorted() where map[courseNo] == nil {
                let assigned = Self.pickUnusedHex(seed: courseNo, used: used, palette: palette)
                map[courseNo] = assigned
                used.insert(assigned)
                mutated = true
            }
            return mutated
        }
        if didMutate { persist() }
    }

    func setColor(hex newHex: UInt32, for courseNo: String, palette: [UInt32]) {
        let didMutate: Bool = lock.withLock {
            if map[courseNo] == newHex { return false }
            // Find every other course holding this hex (normally at most one,
            // but tolerate duplicates that could survive an aborted migration)
            // and release them before reassignment so the picker can choose
            // the just-freed hex if it ends up being the only valid option.
            let displaced = map.compactMap { entry -> String? in
                entry.key != courseNo && entry.value == newHex ? entry.key : nil
            }
            map[courseNo] = newHex
            for d in displaced { map.removeValue(forKey: d) }
            var used = Set(map.values)
            for d in displaced {
                let assigned = Self.pickUnusedHex(seed: d, used: used, palette: palette)
                map[d] = assigned
                used.insert(assigned)
            }
            return true
        }
        if didMutate { persist() }
    }

    func reload() {
        let fresh = DataCache.shared.loadCourseColorMap()
        lock.withLock { map = fresh }
    }

    /// Drop every assignment, then walk `courseNos` and pick fresh unique
    /// colors for each. The sort matches `ensureAssignments` so the first
    /// course (alphabetically by courseNo) always lands on its hash-default
    /// preset when the palette is empty — making the reassignment feel
    /// deterministic for an unchanged roster.
    func reassignAll(courseNos: [String], palette: [UInt32]) {
        lock.withLock {
            map.removeAll(keepingCapacity: true)
            let shuffled = palette.shuffled()
            var used: Set<UInt32> = []
            for courseNo in courseNos.sorted() {
                let assigned = Self.pickUnusedHex(seed: courseNo, used: used, palette: shuffled)
                map[courseNo] = assigned
                used.insert(assigned)
            }
        }
        persist()
    }

    private func persist() {
        let snapshot = lock.withLock { map }
        DataCache.shared.saveCourseColorMap(snapshot)
        // Drives the widget snapshot rewrite. NotificationCenter post is
        // thread-safe, so we don't need to hop back to MainActor for it.
        NotificationCenter.default.post(name: AppConstants.courseColorMapDidChange, object: nil)
    }

    /// Pick the first unused preset starting from the seed's hash slot. When
    /// every preset is already claimed, fall through to a randomly generated
    /// hex (re-rolled until distinct). The 24-bit color space has 16M values
    /// against a roster size in the dozens, so the retry loop converges fast
    /// in practice; the bounded attempt counter guards against a pathological
    /// `used` set that somehow covers a large fraction of RGB.
    private nonisolated static func pickUnusedHex(seed: String, used: Set<UInt32>, palette: [UInt32]) -> UInt32 {
        let start = hashIndex(for: seed, paletteCount: palette.count)
        for offset in 0..<palette.count {
            let candidate = palette[(start + offset) % palette.count]
            if !used.contains(candidate) { return candidate }
        }
        for _ in 0..<256 {
            let candidate = UInt32.random(in: 0...0xFFFFFF)
            if !used.contains(candidate) { return candidate }
        }
        // Pathological fallback: nudge the hash-based pick by the used-set
        // size so we still return *something* distinct from the input seed's
        // first guess. Reaching here implies >16M assigned colors, which is
        // physically impossible for the class roster but keeps the function
        // total.
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
