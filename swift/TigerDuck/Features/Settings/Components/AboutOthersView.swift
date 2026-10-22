import SwiftUI

struct AboutOthersView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @State private var showPrivacyPolicy = false
    @State private var showFeedback = false
    @State private var showDeleteAccount = false

    private static let feedbackURL = AppURLs.issues
    private static let privacyURL = AppURLs.privacyPolicy
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
        .sheet(isPresented: $showFeedback) {
            InAppBrowserView(url: Self.feedbackURL)
                .ignoresSafeArea()
                .keptOverReminders()
        }
        .sheet(isPresented: $showPrivacyPolicy) {
            InAppBrowserView(url: Self.privacyURL)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showDeleteAccount) {
            InAppBrowserView(url: Self.deleteAccountURL)
                .ignoresSafeArea()
                .keptOverReminders()
        }
    }

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
