#if os(iOS)
import SwiftUI

/// "Use another app" (design doc §5): the website's guide, embedded (`MailGuide`), with the
/// @Mail2000 App Store link kept native underneath — the page does not carry it.
struct MailGuideView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @State private var failed = false
    /// Replaced by Retry, so the web view is rebuilt and loads from scratch.
    @State private var attempt = UUID()
    @State private var inAppURL: MailFileItem?

    /// The screen's own page colours, handed to the site as well so the page and the screen
    /// around it are one surface — the page background, not a card colour, or the web view's
    /// edge shows as a seam.
    private let theme = MailHTMLTheme.app

    var body: some View {
        Group {
            if failed {
                ContentUnavailableView {
                    Label(String(localized: "school_mail_guide_load_failed"), systemImage: "wifi.exclamationmark")
                } actions: {
                    Button(String(localized: "action_retry")) {
                        failed = false
                        attempt = UUID()
                    }
                    .buttonStyle(.borderedProminent)
                    Button(String(localized: "school_mail_guide_open_in_browser")) { open(MailGuide.publicURL) }
                }
            } else {
                MailGuideWebView(
                    url: guideURL,
                    background: theme.backgroundColor,
                    onExternalLink: { open($0) },
                    onError: { failed = true }
                )
                .id(attempt)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: theme.backgroundColor))
        .safeAreaInset(edge: .bottom) {
            Link(destination: MailConstants.mail2000AppStoreURL) {
                Label(String(localized: "school_mail_guide_mail2000_link"), systemImage: "arrow.up.forward.app")
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
        .navigationTitle(String(localized: "school_mail_use_other_app"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $inAppURL) { item in InAppBrowserView(url: item.url).ignoresSafeArea() }
    }

    /// Read in `body`, so a language change in Settings reaches the page on the next render
    /// rather than keeping whatever was current when the screen was first built.
    private var guideURL: URL {
        MailGuide.embedURL(isDark: theme.isDark, languageTag: Self.languageTag(appLanguage: appState.appLanguage),
                           background: theme.background, foreground: theme.foreground)
    }

    /// The language the app's own strings are showing in: the chosen one, or for "system" the
    /// localization iOS actually resolved — the same rule `LanguageManager` uses for the UI.
    static func languageTag(appLanguage: String) -> String {
        appLanguage == LanguageManager.system ? (Bundle.main.preferredLocalizations.first ?? "en") : appLanguage
    }

    private func open(_ url: URL) {
        if appState.browserPreference == .inApp {
            inAppURL = MailFileItem(url: url)
        } else {
            openURL(url)
        }
    }
}
#endif
