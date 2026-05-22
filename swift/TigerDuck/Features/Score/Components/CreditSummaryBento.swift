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
                    label: String(localized: "score_credit_earned_label"),
                    breakdown: summary.earned,
                    accent: Color(hex: 0x2ECC71)
                )
                tile(
                    label: String(localized: "score_credit_enrolled_label"),
                    breakdown: summary.enrolled,
                    accent: Color(hex: 0x45B7D1)
                )
            }
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
                    .font(.system(.largeTitle, design: .rounded).weight(.bold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(accent)
                Text(String(localized: "course_detail_credits_label"))
                    .font(TigerDuckTheme.Typography.caption2)
                    .foregroundStyle(Color.textSecondary)
            }

//            HStack(spacing: TigerDuckTheme.Spacing.xs) {
//                breakdownPill(icon: "person.fill", value: breakdown.inPerson, suffix: "in-person")
//                breakdownPill(icon: "dot.radiowaves.left.and.right", value: breakdown.distance, suffix: "distance")
//            }
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
