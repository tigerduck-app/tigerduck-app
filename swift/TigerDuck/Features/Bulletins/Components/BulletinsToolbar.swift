import SwiftUI

/// The bulletin list's toolbar: mark all read, the sync dot, the unread filter and, signed in,
/// the notification settings.
struct BulletinsToolbar: ToolbarContent {
    @Binding var unreadOnly: Bool
    @Binding var showNotificationSettings: Bool
    let unreadShown: [Int]
    let readState: BulletinReadStateStore
    let bulletinsSyncedAt: Date?
    let showsNotificationSettings: Bool

    var body: some ToolbarContent {
        if unreadOnly, !unreadShown.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Button(String(localized: "bulletin_mark_all_read_action")) {
                    readState.markAllRead(unreadShown)
                }
            }
        }
        // The dot opts out of the shared toolbar background: that capsule spans
        // neighbouring items and stays while the dot fades on idle, leaving an
        // empty pill. Bare also matches the pages that draw it in a plain header row.
        if #available(iOS 26, *) {
            ToolbarItem(placement: .topBarTrailing) {
                SyncStatusDot(servers: [.backend], lastSynced: .at(bulletinsSyncedAt))
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                SyncStatusDot(servers: [.backend], lastSynced: .at(bulletinsSyncedAt))
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                unreadOnly.toggle()
            } label: {
                Image(systemName: unreadOnly
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
                    .symbolRenderingMode(.hierarchical)
            }
            .accessibilityLabel(unreadOnly
                ? String(localized: "bulletin_show_all_action")
                : String(localized: "bulletin_show_unread_only_action"))
        }
        if showsNotificationSettings {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showNotificationSettings = true
                } label: {
                    Image(systemName: "bell.badge")
                }
            }
        }
    }
}
