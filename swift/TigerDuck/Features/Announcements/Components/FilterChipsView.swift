import SwiftUI

struct FilterChipsView: View {
    let departments: [String]
    let selected: Set<String>
    let onToggle: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TigerDuckTheme.Spacing.sm) {
                ForEach(departments, id: \.self) { dept in
                    Button {
                        onToggle(dept)
                    } label: {
                        Text(dept)
                            .font(TigerDuckTheme.Typography.caption)
                            .foregroundStyle(selected.contains(dept) ? .white : .textPrimary)
                            .glassChip(isSelected: selected.contains(dept))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        }
    }
}
