import Foundation

/// Canonical TigerDuck-related URLs surfaced in Onboarding and Settings.
/// Mirrors the Android equivalents at `OnboardingScreen.kt:73-76` so both
/// platforms point users at the same website / docs / repos.
enum AppURLs {
    static let website        = URL(string: "https://tigerduck.app")!
    static let github         = URL(string: "https://github.com/tigerduck-app")!
    static let privacyPolicy    = URL(string: "https://tigerduck.app/privacy-policy")!
    static let deleteAccount    = URL(string: "https://tigerduck.app/delete-account")!
    /// The website's TigerSync page: what it is and what it keeps.
    static let learnMoreTigerSync = URL(string: "https://tigerduck.app/tigersync")!
    static let issues         = URL(string: "https://github.com/tigerduck-app/tigerduck-app/issues")!
    /// Public uptime page for every TigerDuck-facing service. Currently
    /// 302s to `status.ntust.org`; opened through ``InAppBrowserView``
    /// (SFSafariViewController), which follows a cross-origin redirect in
    /// place rather than handing off to Safari.
    static let serverStatus   = URL(string: "https://status.tigerduck.app/")!
    static let license        = URL(string: "https://github.com/tigerduck-app/tigerduck-app/blob/main/LICENSE")!
}
