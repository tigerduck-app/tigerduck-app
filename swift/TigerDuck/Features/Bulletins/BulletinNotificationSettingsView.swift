import SwiftUI

/// Placeholder that gets fleshed out in the next checkpoint. Kept in the
/// tree so `BulletinsView` can open a navigation destination today.
struct BulletinNotificationSettingsView: View {
    let taxonomy: BulletinTaxonomyStore

    var body: some View {
        ContentUnavailableView(
            "通知設定", systemImage: "bell.badge",
            description: Text("建構中")
        )
        .navigationTitle("通知設定")
        .navigationBarTitleDisplayMode(.inline)
    }
}
