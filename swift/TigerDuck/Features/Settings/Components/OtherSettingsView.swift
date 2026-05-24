import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Sub-page collecting the "miscellaneous" settings that used to live as a
/// run of header-less Sections at the bottom of `SettingsView`'s
/// "Other settings" block. Lives behind a NavigationLink in SettingsView so
/// the top-level list stays short.
struct OtherSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @State private var showLicense = false
    @State private var showPrivacyPolicy = false
    @State private var showFeedback = false
    @State private var showDeleteAccount = false
    @State private var showReassignColorsConfirm = false

    private static let feedbackURL = AppURLs.issues
    private static let privacyURL = AppURLs.privacyPolicy
    private static let licenseURL = AppURLs.license
    private static let deleteAccountURL = AppURLs.deleteAccount

    var body: some View {
        @Bindable var appState = appState
        List {
            // Each row keeps its own Section so the cards stay visually
            // separated — same arrangement the rows had when they lived
            // directly in SettingsView under the "Other settings" header.
            Section {
                Toggle(String(localized: "settings_invert_slider_direction"), isOn: $appState.invertSliderDirection)
            }
            #if os(iOS)
            // Flip-to-Library: only meaningful when the library feature is
            // on (the gesture routes to the Library tab) and only available
            // on iPhone (iPad use case is unclear and the issue scope says
            // "phone only"). Mirrors the Android equivalent in
            // `Settings → 圖書館 → 翻轉開啟圖書館 QR`.
            //
            // The row is rendered (not hidden) even when library is off so
            // the user can see the preference exists and inspect its state
            // before enabling library — hiding it caused users who turned
            // library off-then-on to be silently re-armed.
            if UIDevice.current.userInterfaceIdiom == .phone && FlipDetector.isSupported {
                Section {
                    Toggle(
                        String(localized: "settings_flip_to_library_title"),
                        isOn: $appState.flipToLibraryEnabled
                    )
                    .disabled(!appState.libraryFeatureEnabled)
                } footer: {
                    Text(String(localized: "settings_flip_to_library_summary"))
                }
            }
            #endif
            Section {
                Button {
                    showReassignColorsConfirm = true
                } label: {
                    Text(String(localized: "settings_reset_course_colors"))
                        .foregroundStyle(.primary)
                }
            }
            Section {
                Button {
                    if appState.browserPreference == .inApp {
                        showFeedback = true
                    } else {
                        openURL(Self.feedbackURL)
                    }
                } label: {
                    Text(String(localized: "settings_feedback_bug_report"))
                        .foregroundStyle(.primary)
                }
                Button {
                    if appState.browserPreference == .inApp {
                        showPrivacyPolicy = true
                    } else {
                        openURL(Self.privacyURL)
                    }
                } label: {
                    Text(String(localized: "settings_privacy_policy"))
                        .foregroundStyle(.primary)
                }
                Button(String(localized: "settings_open_source_licenses")) {
                    if appState.browserPreference == .inApp {
                        showLicense = true
                    } else {
                        openURL(Self.licenseURL)
                    }
                }
                .foregroundStyle(.primary)
                NavigationLink(String(localized: "settings_view_source_code")) {
                    SourceCodePickerView()
                }
                Button {
                    if appState.browserPreference == .inApp {
                        showDeleteAccount = true
                    } else {
                        openURL(Self.deleteAccountURL)
                    }
                } label: {
                    Text(String(localized: "settings_delete_account"))
                        .foregroundStyle(.primary)
                }
            }
        }
        .navigationTitle(String(localized: "settings_section_other_settings"))
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
        .alert(
            String(localized: "settings_reset_course_colors_confirm_title"),
            isPresented: $showReassignColorsConfirm
        ) {
            Button(String(localized: "action_confirm"), role: .destructive) {
                reassignAllCourseColors()
            }
            Button(String(localized: "action_cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "settings_reset_course_colors_confirm_message"))
        }
    }

    /// Rebuild every course's color assignment from scratch using the
    /// unique-color algorithm, then broadcast so Home, Class Table, widgets,
    /// and the Live Activity all pick up the new palette.
    private func reassignAllCourseColors() {
        let courseNos = CanonicalCourseProvider().currentCourses().map(\.courseNo)
        TigerDuckTheme.reassignAll(courseNos: courseNos)
        NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
    }
}
