import SwiftUI

struct HomeTitleBar: View {
    enum Controls {
        case shown
        case spaceOnly
    }

    var controls: Controls = .shown
    let reminders: LiveActivityPreferencesStore
    let onEdit: () -> Void

    var body: some View {
        HStack {
            Text(AppClock.now().greetingText())
                .font(TigerDuckTheme.Typography.title)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            let controlsRow = HStack(spacing: TigerDuckTheme.Spacing.lg) {
                SyncStatusDot(servers: [.moodle, .backend], lastSynced: .schoolData)
                PageMenuButton(page: .home, accessibilityLabel: String(localized: "home_more_actions")) {
                    Button { onEdit() } label: {
                        Label(String(localized: "home_edit"), systemImage: "pencil")
                    }
                    Section { HomeMenuToggles(reminders: reminders) }
                    Section { FullSettingsButton() }
                }
            }
            switch controls {
            case .shown: controlsRow
            case .spaceOnly: controlsRow.hidden()
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }
}

private struct HomeMenuToggles: View {
    @Bindable var reminders: LiveActivityPreferencesStore
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        HomeDisplayToggles(preferences: preferences)
        PageMenuToggle(row: .assignmentReminders, isOn: $reminders.isAssignmentReminderEnabled)
        PageMenuToggle(row: .liveActivity, isOn: $reminders.isLiveActivityEnabled)
    }
}
