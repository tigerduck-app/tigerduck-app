import SwiftUI

/// Horizontal scrollable bar of org/tag filter chips. Taxonomy is supplied
/// by the caller so the same bar can render either dimension.
struct BulletinFilterBar: View {
    let title: String
    let options: [(id: String, label: String)]
    let selected: Set<String>
    let onToggle: (String) -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        let policy = appState.visualStylePolicy
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
            Text(title)
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: TigerDuckTheme.Spacing.sm) {
                    ForEach(options, id: \.id) { option in
                        Button {
                            onToggle(option.id)
                        } label: {
                            Text(option.label)
                                .font(TigerDuckTheme.Typography.caption)
                                .foregroundStyle(chipLabelColor(
                                    isSelected: selected.contains(option.id),
                                    policy: policy
                                ))
                                .presetChip(policy: policy, isSelected: selected.contains(option.id))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            }
        }
    }

    private func chipLabelColor(isSelected: Bool, policy: VisualStylePolicy) -> Color {
        switch policy.chipStyle {
        case .glass:
            return isSelected ? .white : .textPrimary
        case .filledCapsule:
            return isSelected ? .white : .primary
        }
    }
}
