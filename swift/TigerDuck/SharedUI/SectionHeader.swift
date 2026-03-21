import SwiftUI

struct SectionHeader: View {
    let title: String
    var trailing: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(TigerDuckTheme.Typography.headline)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            if let trailing, let action {
                Button(trailing, action: action)
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.accentPrimary)
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.top, TigerDuckTheme.Spacing.md)
    }
}
