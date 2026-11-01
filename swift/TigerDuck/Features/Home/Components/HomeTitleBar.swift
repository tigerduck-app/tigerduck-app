import SwiftUI

struct HomeTitleBar: View {
    enum Controls {
        case shown
        case spaceOnly
    }

    var controls: Controls = .shown
    let onEdit: () -> Void

    var body: some View {
        HStack {
            Text(AppClock.now().greetingText())
                .font(TigerDuckTheme.Typography.title)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            let controlsRow = HStack(spacing: TigerDuckTheme.Spacing.lg) {
                SyncStatusDot(servers: [.moodle, .backend], lastSynced: .schoolData)
                HeaderMenuButton(accessibilityLabel: String(localized: "home_more_actions")) {
                    Button { onEdit() } label: {
                        Label(String(localized: "home_edit"), systemImage: "pencil")
                    }
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
