import SwiftUI

struct AboutOthersView: View {
    @Environment(\.openURL) private var openURL

    private static let feedbackURL = AppURLs.issues
    private static let privacyURL = AppURLs.privacyPolicy
    private static let deleteAccountURL = AppURLs.deleteAccount

    var body: some View {
        List {
            Section {
                Button {
                    openURL(Self.feedbackURL)
                } label: {
                    linkLabel("settings_feedback_bug_report")
                }
                Button {
                    openURL(Self.privacyURL)
                } label: {
                    linkLabel("settings_privacy_policy")
                }
                Button {
                    openURL(Self.deleteAccountURL)
                } label: {
                    linkLabel("settings_delete_account")
                }
                NavigationLink(String(localized: "settings_open_source_licenses")) {
                    OpenSourceLicensesView()
                }
                NavigationLink(String(localized: "settings_view_source_code")) {
                    SourceCodePickerView()
                }
            }
        }
        .navigationTitle(String(localized: "settings_about_others"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A row that leaves this page: tinted, with the same trailing glyph
    /// `SettingsView` puts on Official website and Check server status.
    ///
    /// Not `.foregroundStyle(.primary)`, which renders a Button's label as
    /// ordinary settings text, so nothing would mark the row as tappable or as
    /// a web link.
    private func linkLabel(_ key: String.LocalizationValue) -> some View {
        HStack {
            Text(String(localized: key))
                .foregroundStyle(.tint)
            Spacer()
            Image(systemName: "arrow.up.right.square")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
