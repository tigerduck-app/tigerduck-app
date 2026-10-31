import SwiftUI

/// The settings list's accounts: NTUST, the library and School Mail, each with its sign-in or
/// sign-out button.
struct SettingsAccountSection: View {
    let sheets: SettingsSheetState

    @Environment(AppEnvironment.self) private var app

    var body: some View {
        Section(String(localized: "settings_section_account")) {
            ntustAccountRow
            libraryAccountRow
            #if os(iOS)
            if SchoolMailAvailability.isEnabled {
                schoolMailAccountRow
            }
            #endif
        }
    }

    private var ntustAccountRow: some View {
        accountRow(
            title: String(localized: "settings_account_ntust_system"),
            isLoggedIn: app.authService.hasStoredCredentials,
            detail: app.authService.storedStudentId,
            onLogin: { app.router.presentNTUSTLogin() },
            onLogout: {
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
            title: String(localized: "settings_account_library_system"),
            isLoggedIn: app.library.isLoggedIn,
            detail: app.library.username,
            onLogin: { sheets.showLibraryLogin = true },
            onLogout: { app.library.logout() }
        )
    }

    #if os(iOS)
    private var schoolMailAccountRow: some View {
        let mail = MailAccountManager.shared
        return accountRow(
            title: String(localized: "school_mail_account_title"),
            isLoggedIn: mail.isLoggedIn && !mail.authFailed,
            detail: mail.studentID,
            onLogin: { sheets.showSchoolMailLogin = true },
            onLogout: { mail.logout() }
        )
    }
    #endif

    @ViewBuilder
    private func accountRow(
        title: String,
        isLoggedIn: Bool,
        detail: String?,
        onLogin: @escaping () -> Void,
        onLogout: @escaping () -> Void
    ) -> some View {
        HStack {
            Circle()
                .fill(isLoggedIn ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                if isLoggedIn, let detail {
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
