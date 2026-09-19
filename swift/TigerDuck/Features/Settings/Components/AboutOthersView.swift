import SwiftUI

/// Sub-page behind the "Others" row under Official website in
/// `SettingsView`'s About section: the links about the project rather than
/// the app's own settings — feedback, privacy policy, account deletion,
/// licence and source code. The settings themselves are on
/// `OtherSettingsView`. Android has the same page; the Mac lists these
/// links on its own About tab instead.
struct AboutOthersView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @State private var showLicense = false
    @State private var showPrivacyPolicy = false
    @State private var showFeedback = false
    @State private var showDeleteAccount = false

    private static let feedbackURL = AppURLs.issues
    private static let privacyURL = AppURLs.privacyPolicy
    private static let licenseURL = AppURLs.license
    private static let deleteAccountURL = AppURLs.deleteAccount

    var body: some View {
        List {
            Section {
                Button {
                    if appState.browserPreference == .inApp {
                        showFeedback = true
                    } else {
                        openURL(Self.feedbackURL)
                    }
                } label: {
                    linkLabel("settings_feedback_bug_report")
                }
                Button {
                    if appState.browserPreference == .inApp {
                        showPrivacyPolicy = true
                    } else {
                        openURL(Self.privacyURL)
                    }
                } label: {
                    linkLabel("settings_privacy_policy")
                }
                Button {
                    if appState.browserPreference == .inApp {
                        showDeleteAccount = true
                    } else {
                        openURL(Self.deleteAccountURL)
                    }
                } label: {
                    linkLabel("settings_delete_account")
                }
                Button {
                    if appState.browserPreference == .inApp {
                        showLicense = true
                    } else {
                        openURL(Self.licenseURL)
                    }
                } label: {
                    linkLabel("settings_open_source_licenses")
                }
                NavigationLink(String(localized: "settings_view_source_code")) {
                    SourceCodePickerView()
                }
            }
        }
        .navigationTitle(String(localized: "settings_about_others"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showFeedback) {
            InAppBrowserView(url: Self.feedbackURL)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showPrivacyPolicy) {
            InAppBrowserView(url: Self.privacyURL)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showLicense) {
            InAppBrowserView(url: Self.licenseURL)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showDeleteAccount) {
            InAppBrowserView(url: Self.deleteAccountURL)
                .ignoresSafeArea()
        }
    }

    /// A row that leaves this page: tinted, with the same trailing glyph
    /// `SettingsView` puts on Official website and Check server status.
    ///
    /// Not `.foregroundStyle(.primary)`, which renders a Button's label as
    /// ordinary settings text — nothing about the row would say it was
    /// tappable, let alone that it opened a web page. The glyph follows the
    /// browser preference for the same reason that one does: an arrow out
    /// of the box when the link hands off to the browser, an arrow into a
    /// card when it opens as a sheet over the app.
    private func linkLabel(_ key: String.LocalizationValue) -> some View {
        HStack {
            Text(String(localized: key))
                .foregroundStyle(.tint)
            Spacer()
            Image(systemName: appState.browserPreference == .inApp
                  ? "rectangle.portrait.and.arrow.right"
                  : "arrow.up.right.square")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
