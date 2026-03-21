import SwiftUI

struct GreetingHeaderView: View {
    let username: String

    var body: some View {
        HStack {
            Text("\(Date().greetingText())，\(username)")
                .font(TigerDuckTheme.Typography.title)
                .foregroundStyle(Color.textPrimary)
            Spacer()
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.top, TigerDuckTheme.Spacing.md)
    }
}
