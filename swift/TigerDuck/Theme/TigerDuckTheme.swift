import SwiftUI

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
    static let courseColors: [Color] = [
        Color(hex: 0xFF6B6B), // 珊瑚紅
        Color(hex: 0x4ECDC4), // 青綠
        Color(hex: 0x45B7D1), // 天藍
        Color(hex: 0xF39C12), // 橘橙
        Color(hex: 0xDDA0DD), // 梅紫
        Color(hex: 0x2ECC71), // 翡翠綠
        Color(hex: 0xE74C3C), // 磚紅
        Color(hex: 0x3498DB), // 寶藍
        Color(hex: 0xF7DC6F), // 金黃
        Color(hex: 0x9B59B6), // 紫羅蘭
        Color(hex: 0x1ABC9C), // 碧綠
        Color(hex: 0xE67E22), // 南瓜橘
        Color(hex: 0x85C1E9), // 淺藍
        Color(hex: 0xD35400), // 焦橙
        Color(hex: 0x27AE60), // 森林綠
        Color(hex: 0xC0392B), // 酒紅
        Color(hex: 0x8E44AD), // 深紫
        Color(hex: 0x16A085), // 松綠
        Color(hex: 0xF1C40F), // 向日葵黃
        Color(hex: 0x2980B9), // 鈷藍
    ]

    /// Cache mapping courseNo → Color. Populated lazily and purely as a
    /// lookup optimization — values are derived from `courseColor(for:)`
    /// and never depend on which other courses are in the current list.
    private(set) static var courseColorMap: [String: Color] = [:]

    /// User-chosen palette-index overrides keyed by courseNo. Loaded lazily
    /// from disk on first access so the app-launch sequence does not block
    /// on DataCache.
    private(set) static var courseCustomColors: [String: Int] = DataCache.shared.loadCourseCustomColors()

    /// Populate / refresh the color cache for the given courses. Colors are a
    /// pure function of `courseNo`, so reloading the same (or a different)
    /// semester never reshuffles already-seen courses. New entries are added;
    /// existing entries are kept as-is.
    static func buildCourseColorMap(courseNos: [String]) {
        var map = courseColorMap
        for courseNo in courseNos where map[courseNo] == nil {
            map[courseNo] = stableColor(for: courseNo)
        }
        courseColorMap = map
    }

    static func courseColor(for courseNo: String) -> Color {
        if let index = courseCustomColors[courseNo], courseColors.indices.contains(index) {
            return courseColors[index]
        }
        if let color = courseColorMap[courseNo] {
            return color
        }
        return stableColor(for: courseNo)
    }

    /// Palette index currently in effect for this course, whether from an
    /// explicit override or the hash-based default. Used by the color picker
    /// to highlight the current selection.
    static func paletteIndex(for courseNo: String) -> Int {
        if let index = courseCustomColors[courseNo], courseColors.indices.contains(index) {
            return index
        }
        let hash = courseNo.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        return abs(hash) % courseColors.count
    }

    /// Whether this course has been explicitly recolored by the user.
    static func hasCustomColor(for courseNo: String) -> Bool {
        courseCustomColors[courseNo] != nil
    }

    /// Persist a new palette-index override for this course and invalidate
    /// the fast-path cache entry so the next read re-derives.
    static func setCustomColor(index: Int, for courseNo: String) {
        guard courseColors.indices.contains(index) else { return }
        courseCustomColors[courseNo] = index
        courseColorMap.removeValue(forKey: courseNo)
        DataCache.shared.saveCourseCustomColors(courseCustomColors)
    }

    /// Drop the override for this course so it falls back to the deterministic
    /// default.
    static func clearCustomColor(for courseNo: String) {
        guard courseCustomColors.removeValue(forKey: courseNo) != nil else { return }
        courseColorMap.removeValue(forKey: courseNo)
        DataCache.shared.saveCourseCustomColors(courseCustomColors)
    }

    /// Refresh the in-memory override map from disk. Called when the
    /// underlying user-scoped data is swapped (e.g. logout/login).
    static func reloadCustomColors() {
        courseCustomColors = DataCache.shared.loadCourseCustomColors()
        courseColorMap.removeAll()
    }

    /// Deterministic hash → palette index. Stable across launches and
    /// independent of the surrounding course list.
    private static func stableColor(for courseNo: String) -> Color {
        let hash = courseNo.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        return courseColors[abs(hash) % courseColors.count]
    }
}
