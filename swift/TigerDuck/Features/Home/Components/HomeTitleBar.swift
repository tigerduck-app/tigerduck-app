import SwiftUI

/// Home's greeting with the sync dot and the menu that starts editing.
///
/// The edit page keeps the controls' space but hides them. The menu reads as an edit control,
/// and the edit page's bar sits a navigation bar lower, below Done, so with a dot on both
/// pages the cross-fade between them would show two.
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
