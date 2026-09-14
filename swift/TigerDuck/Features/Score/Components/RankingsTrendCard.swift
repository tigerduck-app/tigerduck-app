import SwiftUI

/// The iPhone's GPA trend card: a title, a picker between the per-semester
/// and cumulative views — they answer different questions ("how did I do
/// last term" vs. "how am I trending") — and `GPATrendChart`, which draws
/// the line and the readout under it.
struct RankingsTrendCard: View {
    @Environment(AppState.self) private var appState

    let points: [GPATrendPoint]
    @Binding var scope: ScoreViewModel.RankingScope

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            header

            if points.isEmpty {
                Text(String(localized: "score_no_ranking_data"))
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, TigerDuckTheme.Spacing.lg)
            } else {
                GPATrendChart(points: points, scope: scope)
            }
        }
        .padding(TigerDuckTheme.Spacing.md)
        .presetCard(policy: appState.visualStylePolicy)
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    private var header: some View {
        HStack {
            Text(String(localized: "score_gpa_trend_title"))
                .font(TigerDuckTheme.Typography.headline)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Picker("Scope", selection: $scope) {
                ForEach(ScoreViewModel.RankingScope.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
        }
    }
}
