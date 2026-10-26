#if os(iOS)
import SwiftUI

struct MailSettingsView: View {
    @State private var displayNameDraft = ""
    private let account = MailAccountManager.shared

    static func displayNameIsEnabled(isLoggedIn: Bool) -> Bool {
        isLoggedIn
    }

    var body: some View {
        List {
            Section {
                TextField(String(localized: "school_mail_settings_display_name"), text: $displayNameDraft)
                    .textContentType(.name)
                    .submitLabel(.done)
                    .onSubmit { account.displayName = displayNameDraft.mailNonEmpty }
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
        .onAppear { displayNameDraft = account.displayName ?? "" }
        .onDisappear { account.displayName = displayNameDraft.mailNonEmpty }
    }
}
#endif
