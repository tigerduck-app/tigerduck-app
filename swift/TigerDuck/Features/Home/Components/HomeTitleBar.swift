import SwiftUI

struct HomeTitleBar: View {
    var showsControls = true
    let onEdit: () -> Void

    var body: some View {
        HStack {
            Text(AppClock.now().greetingText())
                .font(TigerDuckTheme.Typography.title)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            let controls = HStack(spacing: TigerDuckTheme.Spacing.lg) {
                SyncStatusDot(servers: [.moodle, .backend], lastSynced: .schoolData)
                HeaderMenuButton(accessibilityLabel: String(localized: "home_more_actions")) {
                    Button { onEdit() } label: {
                        Label(String(localized: "home_edit"), systemImage: "pencil")
                    }
                }
            }
            if showsControls { controls } else { controls.hidden() }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }
}
