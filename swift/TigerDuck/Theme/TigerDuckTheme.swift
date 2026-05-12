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
    static let coursePaletteHexes: [UInt] = [
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

    static let courseColors: [Color] = coursePaletteHexes.map { Color(hex: $0) }

    /// "#RRGGBB" hex for the course's current palette index. Mirrors
    /// `courseColor(for:)` but returns the wire-format string used by
    /// `WatchPayloadEncoder`.
    static func courseColorHex(for courseNo: String) -> String {
        let idx = paletteIndex(for: courseNo)
        let hex = coursePaletteHexes[idx]
        return String(format: "#%06X", hex)
    }

    /// Lock-protected mutable state for the per-course color caches.
    /// `buildCourseColorMap` runs from background sync while
    /// `setCustomColor` runs on MainActor (settings UI); without
    /// synchronization the concurrent mutations race against
    /// SDCourse-driven reads on the render thread. Swift dictionaries
    /// are not thread-safe, so the access is funneled through
    /// `os_unfair_lock` via the wrapper below.
    private static let state = ColorState()

    /// Snapshot of the current courseNo → palette-index overrides. Read
    /// rarely (settings sheet) and never concurrently with mutations on
    /// the same key, so taking the lock for the snapshot is cheap.
    static var courseCustomColors: [String: Int] {
        state.snapshotCustom()
    }

    /// Populate / refresh the color cache for the given courses. Colors are a
    /// pure function of `courseNo`, so reloading the same (or a different)
    /// semester never reshuffles already-seen courses. New entries are added;
    /// existing entries are kept as-is.
    static func buildCourseColorMap(courseNos: [String]) {
        state.merge(courseNos: courseNos) { stableColor(for: $0) }
    }

    static func courseColor(for courseNo: String) -> Color {
        state.color(for: courseNo, palette: courseColors) ?? stableColor(for: courseNo)
    }

    /// Palette index currently in effect for this course, whether from an
    /// explicit override or the hash-based default. Used by the color picker
    /// to highlight the current selection.
    static func paletteIndex(for courseNo: String) -> Int {
        if let custom = state.customIndex(for: courseNo), courseColors.indices.contains(custom) {
            return custom
        }
        let hash = courseNo.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        return abs(hash) % courseColors.count
    }

    /// Whether this course has been explicitly recolored by the user.
    static func hasCustomColor(for courseNo: String) -> Bool {
        state.customIndex(for: courseNo) != nil
    }

    /// Persist a new palette-index override for this course and invalidate
    /// the fast-path cache entry so the next read re-derives.
    static func setCustomColor(index: Int, for courseNo: String) {
        guard courseColors.indices.contains(index) else { return }
        let snapshot = state.setCustom(index: index, for: courseNo)
        DataCache.shared.saveCourseCustomColors(snapshot)
    }

    /// Drop the override for this course so it falls back to the deterministic
    /// default.
    static func clearCustomColor(for courseNo: String) {
        guard let snapshot = state.clearCustom(for: courseNo) else { return }
        DataCache.shared.saveCourseCustomColors(snapshot)
    }

    /// Refresh the in-memory override map from disk. Called when the
    /// underlying user-scoped data is swapped (e.g. logout/login).
    static func reloadCustomColors() {
        let custom = DataCache.shared.loadCourseCustomColors()
        state.reload(custom: custom)
    }

    /// Deterministic hash → palette index. Stable across launches and
    /// independent of the surrounding course list.
    private static func stableColor(for courseNo: String) -> Color {
        let hash = courseNo.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        return courseColors[abs(hash) % courseColors.count]
    }
}

/// Wraps the lock + state for `TigerDuckTheme`. Hidden behind a class so
/// the generic `OSAllocatedUnfairLock<T>` is not visible at the use
/// sites (the prior generic-in-static-let arrangement triggered the
/// Swift type-checker's complexity budget on the surrounding palette
/// literal).
private final class ColorState: @unchecked Sendable {
    private nonisolated(unsafe) var map: [String: Color] = [:]
    private nonisolated(unsafe) var custom: [String: Int]
    private let lock = OSAllocatedUnfairLock()

    init() {
        self.custom = DataCache.shared.loadCourseCustomColors()
    }

    func snapshotCustom() -> [String: Int] {
        lock.withLock { custom }
    }

    func customIndex(for courseNo: String) -> Int? {
        lock.withLock { custom[courseNo] }
    }

    func merge(courseNos: [String], stableColor: (String) -> Color) {
        let resolved = courseNos.map { ($0, stableColor($0)) }
        lock.withLock {
            for (courseNo, color) in resolved where map[courseNo] == nil {
                map[courseNo] = color
            }
        }
    }

    func color(for courseNo: String, palette: [Color]) -> Color? {
        lock.withLock {
            if let index = custom[courseNo], palette.indices.contains(index) {
                return palette[index]
            }
            return map[courseNo]
        }
    }

    func setCustom(index: Int, for courseNo: String) -> [String: Int] {
        lock.withLock {
            custom[courseNo] = index
            map.removeValue(forKey: courseNo)
            return custom
        }
    }

    func clearCustom(for courseNo: String) -> [String: Int]? {
        lock.withLock {
            guard custom.removeValue(forKey: courseNo) != nil else { return nil }
            map.removeValue(forKey: courseNo)
            return custom
        }
    }

    func reload(custom: [String: Int]) {
        lock.withLock {
            self.custom = custom
            self.map.removeAll()
        }
    }
}
