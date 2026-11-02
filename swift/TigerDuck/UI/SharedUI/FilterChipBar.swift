import SwiftUI

struct FilterChipBar: View {
    var title: String? = nil
    let options: [(id: String, label: String)]
    let selected: Set<String>
    let policy: VisualStylePolicy
    let onToggle: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
            if let title {
                Text(title)
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: TigerDuckTheme.Spacing.sm) {
                    ForEach(options, id: \.id) { option in
                        Button {
                            onToggle(option.id)
                        } label: {
                            Text(option.label)
                                .font(TigerDuckTheme.Typography.caption)
                                .foregroundStyle(chipLabelColor(isSelected: selected.contains(option.id)))
                                .presetChip(policy: policy, isSelected: selected.contains(option.id))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            }
        }
    }

    private func chipLabelColor(isSelected: Bool) -> Color {
        switch policy.chipStyle {
        case .glass:
            return isSelected ? .white : .textPrimary
        case .filledCapsule:
            return isSelected ? .white : .primary
        }
    }
}
