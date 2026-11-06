import SwiftUI

nonisolated struct SettingsState: Equatable, Sendable {
    nonisolated struct Account: Equatable, Sendable {
        var isSignedIn = false
        var name: String?
    }

    var school = Account()
    var library = Account()
    var mail = Account()
    var mailSignInFailed = false
    var isCloudSyncOn = false
    var isChineseUI = false
    var usesEnglishClassroomNames = false
    var hasFlipToLibrary = false
    var hasSchoolMail = false
    var hasWhatsNew = false
    var hasMoodleApp = false
    var isCheckingForUpdate = false
}

extension EnvironmentValues {
    @Entry var settingsState = SettingsState()
}

extension View {
    func settingsRow(_ row: SettingsRow) -> some View {
        modifier(SettingsRowModifier(row: row))
    }
}

private struct SettingsRowModifier: ViewModifier {
    let row: SettingsRow
    @Environment(\.settingsState) private var state

    func body(content: Content) -> some View {
        content
            .disabled(because: row.closedReason(in: state))
            .id(row)
    }
}
