import SwiftUI

/// Two-card bento showing earned and enrolled credits.
///
/// Only `CreditBreakdown.total` is surfaced. The `inPerson` / `distance`
/// split the model also carries was written alongside this view in dbcad1d
/// but committed already commented out, with its labels as bare English
/// literals rather than `String(localized:)` — which is what it would need
/// before it could ship in a 67-locale app.
struct CreditSummaryBento: View {
    @Environment(AppState.self) private var appState

    let summary: CreditSummary

    var body: some View {
        VStack(spacing: TigerDuckTheme.Spacing.sm) {
            HStack(spacing: TigerDuckTheme.Spacing.sm) {
                tile(
                    label: String(localized: "score_credit_earned"),
                    breakdown: summary.earned,
                    accent: Color(hex: 0x2ECC71)
                )
                tile(
                    label: String(localized: "score_credit_enrolled"),
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(TigerDuckTheme.Spacing.md)
        .presetCard(policy: appState.visualStylePolicy)
        .frame(maxWidth: wide ? .infinity : nil)
    }
}
