import Foundation

enum AppURLs {
    static let website        = URL(string: "https://tigerduck.app")!
    static let github         = URL(string: "https://github.com/tigerduck-app")!
    static let privacyPolicy    = URL(string: "https://tigerduck.app/privacy-policy")!
    static let deleteAccount    = URL(string: "https://tigerduck.app/delete-account")!
    static let learnMoreTigerSync = URL(string: "https://tigerduck.app/tigersync")!
    static let issues         = URL(string: "https://github.com/tigerduck-app/tigerduck-app/issues")!
    /// Public uptime page for every TigerDuck-facing service. It 302s to
    /// `status.ntust.org`, which the system browser follows in place.
    static let serverStatus   = URL(string: "https://status.tigerduck.app/")!
}
