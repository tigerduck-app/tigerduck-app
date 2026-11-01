#if os(iOS)
import SwiftUI

struct MailSettingsView: View {
    @Environment(\.settingsState) private var state
    @State private var draft = DisplayNameDraft(of: MailAccountManager.shared)
    private let account = MailAccountManager.shared

    /// A name being edited, saved only into the sign-in it was copied from.
    struct DisplayNameDraft {
        var name: String
        let signIn: SignIn

        init(of account: MailAccountManager) {
            (name, signIn) = (account.displayName ?? "", account.session.currentSignIn)
        }

        func save(to account: MailAccountManager) {
            account.setDisplayName(name.mailNonEmpty, for: signIn)
        }
    }

    var body: some View {
        List {
            Section {
                NavigationLink(SettingsRow.mailNotifications.label) { MailNotificationSettingsView() }
                    .settingsRow(.mailNotifications)
            }

            Section {
                TextField(SettingsRow.mailDisplayName.label, text: $draft.name)
                    .textContentType(.name)
                    .submitLabel(.done)
                    .onSubmit { draft.save(to: account) }
                    .settingsRow(.mailDisplayName)
            } header: {
                Text(SettingsRow.mailDisplayName.label)
            } footer: {
                Text(String(localized: "school_mail_settings_display_name_hint"))
            }

            StorageKindSection(kind: .mail)
        }
        .onAppear { draft = DisplayNameDraft(of: account) }
        .onDisappear { if SettingsGate.mailSignIn.isOpen(in: state) { draft.save(to: account) } }
    }
}
#endif
