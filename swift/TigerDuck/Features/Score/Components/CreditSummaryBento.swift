import SwiftUI

/// Three-card bento showing earned / enrolled / total credits. Each card
/// expands an "in-person + distance" breakdown underneath the headline
/// number so the layered totals are legible without a legend.
struct CreditSummaryBento: View {
    @Environment(AppState.self) private var appState

    let summary: CreditSummary

    var body: some View {
        VStack(spacing: TigerDuckTheme.Spacing.sm) {
            HStack(spacing: TigerDuckTheme.Spacing.sm) {
                tile(
                    label: "已實得",
                    breakdown: summary.earned,
                    accent: Color(hex: 0x2ECC71)
                )
                tile(
                    label: "修習中",
                    breakdown: summary.enrolled,
                    accent: Color(hex: 0x45B7D1)
                )
            }
            tile(
                label: "合計",
                breakdown: summary.total,
                accent: Color(hex: 0xF39C12),
                wide: true
            )
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    @ViewBuilder
    private func tile(
        label: String,
        breakdown: CreditBreakdown,
        accent: Color,
        wide: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
            Text(label)
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)

            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text("\(breakdown.total)")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                Text("學分")
                    .font(TigerDuckTheme.Typography.caption2)
                    .foregroundStyle(Color.textSecondary)
            }

            HStack(spacing: TigerDuckTheme.Spacing.xs) {
                breakdownPill(icon: "person.fill", value: breakdown.inPerson, suffix: "實體")
                breakdownPill(icon: "dot.radiowaves.left.and.right", value: breakdown.distance, suffix: "遠距")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(TigerDuckTheme.Spacing.md)
        .presetCard(policy: appState.visualStylePolicy)
        .frame(maxWidth: wide ? .infinity : nil)
    }

    private func breakdownPill(icon: String, value: Int, suffix: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
            Text("\(value) \(suffix)")
                .font(.caption2)
        }
        .foregroundStyle(Color.textSecondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.white.opacity(0.06), in: Capsule())
    }
}
