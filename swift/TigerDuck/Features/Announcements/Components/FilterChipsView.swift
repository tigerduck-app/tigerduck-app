import SwiftUI

struct FilterChipsView: View {
    let departments: [String]
    let selected: Set<String>
    let onToggle: (String) -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        let policy = appState.visualStylePolicy
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TigerDuckTheme.Spacing.sm) {
                ForEach(departments, id: \.self) { dept in
                    Button {
                        onToggle(dept)
                    } label: {
                        Text(dept)
                            .font(TigerDuckTheme.Typography.caption)
                            .foregroundStyle(chipLabelColor(
                                isSelected: selected.contains(dept),
                                policy: policy
                            ))
                            .presetChip(policy: policy, isSelected: selected.contains(dept))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
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
