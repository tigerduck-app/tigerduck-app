import SwiftUI

struct SettingsAccountSection: View {
    let sheets: SettingsSheetState

    @Environment(AppEnvironment.self) private var app: AppEnvironment?
    @Environment(\.settingsState) private var state

    var body: some View {
        Section(String(localized: "settings_section_account")) {
            ntustAccountRow
                .settingsRow(.schoolAccount)
            libraryAccountRow
                .settingsRow(.libraryAccount)
            #if os(iOS)
            if SettingsRow.mailAccount.isShown(in: state) {
                schoolMailAccountRow
                    .settingsRow(.mailAccount)
            }
            #endif
        }
    }

    private var ntustAccountRow: some View {
        accountRow(
            title: SettingsRow.schoolAccount.label,
            account: state.school,
            onLogin: { app?.router.presentNTUSTLogin() },
            onLogout: {
                guard let app else { return }
                Task {
                    let unsynced = await app.signOutCheck.deletesUnsyncedData()
                    guard app.authService.hasStoredCredentials else { return }
                    ImportedClassTableStore.shared.requestSignOut(
                        unsyncedData: unsynced,
                        confirm: { sheets.signOutLines = $0; sheets.confirmsSignOut = true },
                        signOut: { SignOutPlan.school(app).run() }
                    )
                }
            }
        )
    }

    private var libraryAccountRow: some View {
        accountRow(
            title: SettingsRow.libraryAccount.label,
            account: state.library,
            onLogin: { sheets.showLibraryLogin = true },
            onLogout: { app?.library.logout() }
        )
    }

    #if os(iOS)
    private var schoolMailAccountRow: some View {
        var mail = state.mail
        mail.isSignedIn = mail.isSignedIn && !state.mailSignInFailed
        return accountRow(
            title: SettingsRow.mailAccount.label,
            account: mail,
            onLogin: { sheets.showSchoolMailLogin = true },
            onLogout: { MailAccountManager.shared.logout() }
        )
    }
    #endif

    @ViewBuilder
    private func accountRow(
        title: String,
        account: SettingsState.Account,
        onLogin: @escaping () -> Void,
        onLogout: @escaping () -> Void
    ) -> some View {
        let isLoggedIn = account.isSignedIn
        HStack {
            Circle()
                .fill(isLoggedIn ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                if isLoggedIn, let detail = account.name {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            accountActionButton(isLoggedIn: isLoggedIn, onLogin: onLogin, onLogout: onLogout)
        }
    }

    @ViewBuilder
    private func accountActionButton(
        isLoggedIn: Bool,
        onLogin: @escaping () -> Void,
        onLogout: @escaping () -> Void
    ) -> some View {
        if isLoggedIn {
            Button(role: .destructive, action: onLogout) {
                Text(String(localized: "action_sign_out"))
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else {
            Button(action: onLogin) {
                Text(String(localized: "action_sign_in"))
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }
}
