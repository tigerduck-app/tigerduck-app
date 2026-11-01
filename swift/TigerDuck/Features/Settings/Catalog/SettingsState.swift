import SwiftUI

/// What decides which Settings rows show and which gates are open. `settingsEnvironment()` reads
/// it from the app; a test sets it above the view instead.
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
    var isCheckingForUpdate = false
}

extension EnvironmentValues {
    @Entry var settingsState = SettingsState()
}

extension View {
    /// Marks a view as `row`: the root list scrolls to it by this id, and a closed gate disables it.
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
