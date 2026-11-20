import SwiftUI

struct BulletinsPageSettingsView: View {
    @Environment(\.settingsState) private var state

    var body: some View {
        if SettingsGate.schoolSignIn.isOpen(in: state) {
            BulletinNotificationSettingsView(taxonomy: .shared)
        } else {
            List {
                BulletinPushSection(
                    pushEnabled: false, authStatus: .notDetermined, isAskingPermission: false,
                    isDisablingPush: false, pushUpdateFailed: false, onEnable: {}, onDisable: {},
                    enableClosedReason: SettingsRow.bulletinPush.closedReason(in: state)
                )
            }
            .listStyle(.insetGrouped)
        }
    }
}
