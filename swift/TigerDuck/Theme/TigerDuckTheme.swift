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

    /// Deterministic color assignment: sorted course list → each gets a unique color index
    private(set) static var courseColorMap: [String: Color] = [:]

    static func buildCourseColorMap(courseNos: [String]) {
        let sorted = courseNos.sorted()
        var map: [String: Color] = [:]
        for (index, courseNo) in sorted.enumerated() {
            map[courseNo] = courseColors[index % courseColors.count]
        }
        courseColorMap = map
    }

    static func courseColor(for courseNo: String) -> Color {
        if let color = courseColorMap[courseNo] {
            return color
        }
        // Fallback: deterministic hash (stable across launches, unlike String.hashValue)
        let hash = courseNo.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        return courseColors[abs(hash) % courseColors.count]
    }
}
