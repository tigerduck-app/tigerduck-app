import SwiftUI

struct CourseListRow: View {
    let color: Color
    let title: String
    let details: [String]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static let textInset: CGFloat = TigerDuckTheme.Spacing.lg + squareSide + TigerDuckTheme.Spacing.md
    private static let squareSide: CGFloat = 16

    var body: some View {
        let wrapsLines = dynamicTypeSize.isAccessibilitySize
        HStack(spacing: TigerDuckTheme.Spacing.md) {
            ColorSquare(color: color, side: Self.squareSide)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TigerDuckTheme.Typography.body.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(wrapsLines ? nil : 1)
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(TigerDuckTheme.Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(wrapsLines ? nil : 1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.vertical, TigerDuckTheme.Spacing.md)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(([title] + details).joined(separator: ", ")))
    }
}

struct ColorSquare: View {
    let color: Color
    let side: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(color)
            .frame(width: side, height: side)
    }
}
