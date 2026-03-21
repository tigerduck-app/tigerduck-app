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

    // MARK: - Course Colors (10-color palette)
    static let courseColors: [Color] = [
        Color(hex: 0xFF6B6B), // 珊瑚紅
        Color(hex: 0x4ECDC4), // 青綠
        Color(hex: 0x45B7D1), // 天藍
        Color(hex: 0x96CEB4), // 鼠尾草綠
        Color(hex: 0xFFEAA7), // 暖黃
        Color(hex: 0xDDA0DD), // 梅紫
        Color(hex: 0x98D8C8), // 薄荷
        Color(hex: 0xF7DC6F), // 金黃
        Color(hex: 0xBB8FCE), // 薰衣草
        Color(hex: 0x85C1E9), // 淺藍
    ]

    static func courseColor(for courseNo: String) -> Color {
        let hash = abs(courseNo.hashValue)
        return courseColors[hash % courseColors.count]
    }
}
