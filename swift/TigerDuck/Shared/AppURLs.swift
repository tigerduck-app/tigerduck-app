import Foundation

/// Canonical TigerDuck-related URLs surfaced in Onboarding and Settings.
/// Mirrors the Android equivalents at `OnboardingScreen.kt:73-76` so both
/// platforms point users at the same website / docs / repos.
enum AppURLs {
    static let website        = URL(string: "https://tigerduck.app")!
    static let github         = URL(string: "https://github.com/tigerduck-app")!
    static let privacyPolicy  = URL(string: "https://tigerduck.app/privacy-policy")!
    static let deleteAccount  = URL(string: "https://tigerduck.app/delete-account")!
    static let issues         = URL(string: "https://github.com/tigerduck-app/tigerduck-app/issues")!
    static let license        = URL(string: "https://github.com/tigerduck-app/tigerduck-app/blob/main/LICENSE")!
}
