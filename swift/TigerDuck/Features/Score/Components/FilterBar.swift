import SwiftUI

/// Search field + status chip row that drives `ScoreViewModel.searchText` and
/// `ScoreViewModel.statusFilter`. Kept deliberately flat (no sheet, no
/// disclosure) so users never need to drill in to see what's applied.
struct FilterBar: View {
    @Environment(AppState.self) private var appState

    @Binding var searchText: String
    @Binding var statusFilter: ScoreViewModel.StatusFilter

    var body: some View {
        VStack(spacing: TigerDuckTheme.Spacing.sm) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.textSecondary)
                TextField("搜尋課程名稱或代碼", text: $searchText)
                    .foregroundStyle(Color.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .presetSearchBarSurface(policy: appState.visualStylePolicy)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: TigerDuckTheme.Spacing.xs) {
                    ForEach(ScoreViewModel.StatusFilter.allCases) { option in
                        Button {
                            statusFilter = option
                        } label: {
                            Text(option.displayName)
                                .font(TigerDuckTheme.Typography.caption)
                                .padding(.horizontal, TigerDuckTheme.Spacing.sm)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .presetChip(
                            policy: appState.visualStylePolicy,
                            isSelected: statusFilter == option
                        )
                    }
                }
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }
}
