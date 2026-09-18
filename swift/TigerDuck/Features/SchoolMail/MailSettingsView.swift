#if os(iOS)
import SwiftUI

/// 信箱設定 (design doc §6.5): the display name and the guide.
///
/// The new-mail switch and 通知診斷 used to live here too. They moved to
/// `MailNotificationSettingsView`, reached from Settings → 通知 with the app's other
/// notification screens — moved, not copied, so only one screen owns the switch.
struct MailSettingsView: View {
    @State private var displayNameDraft = ""
    private let account = MailAccountManager.shared

    /// The display name is written onto outgoing mail, so signed out there is nothing for
    /// it to belong to. Dimmed rather than hidden: the field keeps its place on the screen.
    /// Demo mode counts as signed in, like everywhere else — `isLoggedIn` is the stored
    /// student ID, which a demo login sets like any other.
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
                NavigationLink(String(localized: "school_mail_use_other_app")) { MailGuideView() }
            }
        }
        .navigationTitle(String(localized: "school_mail_account_title"))
        .onAppear { displayNameDraft = account.displayName ?? "" }
        .onDisappear { account.displayName = displayNameDraft.mailNonEmpty }
    }
}
#endif
