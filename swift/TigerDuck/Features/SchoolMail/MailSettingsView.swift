#if os(iOS)
import SwiftUI

struct MailSettingsView: View {
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

    static func displayNameIsEnabled(isLoggedIn: Bool) -> Bool {
        isLoggedIn
    }

    var body: some View {
        List {
            Section {
                TextField(String(localized: "school_mail_settings_display_name"), text: $draft.name)
                    .textContentType(.name)
                    .submitLabel(.done)
                    .onSubmit { draft.save(to: account) }
            } header: {
                Text(String(localized: "school_mail_settings_display_name"))
            } footer: {
                Text(String(localized: "school_mail_settings_display_name_hint"))
            }
            .disabled(!Self.displayNameIsEnabled(isLoggedIn: account.isLoggedIn))

            Section {
                NavigationLink(String(localized: "settings_storage_title")) { StorageSettingsView() }
            }
        }
        .navigationTitle(String(localized: "school_mail_account_title"))
        .onAppear { draft = DisplayNameDraft(of: account) }
        .onDisappear { draft.save(to: account) }
    }
}
#endif
