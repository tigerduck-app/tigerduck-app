import SwiftUI

struct BulletinsToolbar: ToolbarContent {
    @Binding var unreadOnly: Bool
    let unreadShown: [Int]
    let readState: BulletinReadStateStore
    let bulletinsSyncedAt: Date?

    var body: some ToolbarContent {
        // The dot opts out of the shared toolbar background: that capsule spans
        // neighbouring items and stays while the dot fades on idle, leaving an
        // empty pill.
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
            UnreadFilterButton(
                unreadOnly: $unreadOnly,
                accessibilityLabel: String(localized: "bulletin_show_unread_only_action"),
                markAllReadTitle: String(localized: "bulletin_mark_all_read_action"),
                markAllRead: unreadShown.isEmpty ? nil : { readState.markAllRead(unreadShown) }
            ) {
                Image(systemName: $0).symbolRenderingMode(.hierarchical)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            PageMenuButton(page: .bulletins, placement: .toolbar) { PageSettingsButton() }
        }
    }
}
