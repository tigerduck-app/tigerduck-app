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
            Section {
                NavigationLink {
                    FontSizeSettingsView()
                } label: {
                    HStack {
                        Text(String(localized: "settings_font_size_title"))
                            .foregroundStyle(.primary)
                        Spacer()
                        // Locale-aware decimal separator: en "1.20×",
                        // de/fr/es/it "1,20×". `String(format:)` would
                        // be POSIX-only and break the non-period locales.
                        Text(CourseCardFontScale
                            .normalize(appState.courseCardFontScale)
                            .formatted(.number.precision(.fractionLength(2))) + "×")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } footer: {
                Text(String(localized: "settings_font_size_summary"))
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
            // library off-then-on to be silently re-armed with the default-
            // true persisted value. The toggle is also kept enabled in that
            // state so the user can opt out before flipping the library
            // feature back on; the gesture is gated at fire time by
            // `libraryFeatureEnabled` in the coordinator either way.
            if UIDevice.current.userInterfaceIdiom == .phone && FlipDetector.isSupported {
                Section {
                    Toggle(
                        String(localized: "settings_flip_to_library_title"),
                        isOn: $appState.flipToLibraryEnabled
                    )
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
                NavigationLink(String(localized: "settings_api_endpoint")) {
                    DebugEndpointView()
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
                appState.reassignAllCourseColors()
            }
            Button(String(localized: "action_cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "settings_reset_course_colors_confirm_message"))
        }
    }

    /// A row that leaves this page: tinted, with the same trailing glyph
    /// `SettingsView` puts on Official website and Check server status.
    ///
    /// These four were `.foregroundStyle(.primary)`, which renders a
    /// Button's label as ordinary settings text — nothing about the row
    /// said it was tappable, let alone that it opened a web page. The
    /// glyph follows the browser preference for the same reason that one
    /// does: an arrow out of the box when the link hands off to the
    /// browser, an arrow into a card when it opens as a sheet over the
    /// app.
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
