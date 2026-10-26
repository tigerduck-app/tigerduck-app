import Foundation

/// The TigerDuck browser's URL rules: what loads inside, what goes outside, and which Moodle
/// addresses sign the browser in or out. Plain URL checks, so tests need no WebKit.
nonisolated enum BrowserRouting {
    enum Decision: Equatable {
        case load
        /// A page the browser cannot show, plain http or the App Store: it asks before handing
        /// it to the system.
        case openOutside(URL)
        /// A `mailto:` link, for the system's mail app.
        case handOff(URL)
        case refuse
    }

    static let moodleHost = AppConstants.moodleBaseURL.host()!.lowercased()
    static let ssoHost = "ssoam2.ntust.edu.tw"

    /// Moodle's OIDC entry, which signs the browser in with the school SSO session it holds.
    static let webSignInURL = URL.knownGood("https://moodle2.ntust.edu.tw/auth/oidc/?source=loginpage")

    /// `byLinkTap` is whether the student tapped a link: a script's navigation never opens Mail.
    static func decision(for url: URL, byLinkTap: Bool = false) -> Decision {
        switch url.scheme?.lowercased() {
        case "https", "http":
            if isMoodleLogout(url) { return .refuse }
            return url.scheme?.lowercased() == "https" && !isAppStore(url) ? .load : .openOutside(url)
        case "about":
            // Pages open about:blank to write into.
            return url.absoluteString.lowercased() == "about:blank" ? .load : .refuse
        case "mailto":
            return byLinkTap ? .handOff(url) : .refuse
        default:
            return .refuse
        }
    }

    /// https on the default port with no user in the address, on a subdomain of ntust.edu.tw.
    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, let host = host(of: url) else { return false }
        return host.hasSuffix(".ntust.edu.tw")
    }

    /// An App Store page, which the App Store app shows and a web view shows only as a page.
    static func isAppStore(_ url: URL) -> Bool {
        ["apps.apple.com", "itunes.apple.com"].contains(host(of: url))
    }

    /// Moodle's logout and auth_oidc's, as the server reads the path: any case, encoding, doubled
    /// slash, dot segment or trailing path. The session is TigerDuck's to end at its own sign-out.
    static func isMoodleLogout(_ url: URL) -> Bool {
        guard host(of: url) == moodleHost else { return false }
        let path = segments(of: url)
        return path.starts(with: ["login", "logout.php"]) || path.starts(with: ["auth", "oidc", "logout.php"])
    }

    /// Moodle's `/login/` pages, its sign-in form and what that posts to, but not its logout.
    static func isMoodleSignInPage(_ url: URL) -> Bool {
        host(of: url) == moodleHost && segments(of: url).first == "login" && !isMoodleLogout(url)
    }

    /// Moodle's one-time sign-in links (autologin.php), never shown, copied or loaded again.
    static func isMoodleSignInLink(_ url: URL) -> Bool {
        host(of: url) == moodleHost && segments(of: url).starts(with: ["admin", "tool", "mobile"])
    }

    /// A Moodle page a sign-in can return to: not one of the pages it signs in through.
    static func isMoodleReturnPage(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", host(of: url) == moodleHost else { return false }
        return !isMoodleSignInPage(url) && !isMoodleLogout(url) && !isMoodleSignInLink(url)
            && segments(of: url).first != "auth"
    }

    static func hasMoodleSession(_ cookies: [HTTPCookie]) -> Bool {
        cookies.contains { cookie in
            cookie.name.hasPrefix("MoodleSession") && !cookie.value.isEmpty
                && cookie.domain.lowercased().trimmingPrefix(".") == moodleHost
        }
    }

    /// Moodle's session cookie given an expiry, as WebKit keeps a cookie without one in memory only
    /// and the browser keeps its Moodle session across launches. Moodle still ends the session.
    static func lastingSession(_ cookie: HTTPCookie, until expiry: Date) -> HTTPCookie? {
        guard cookie.expiresDate == nil, hasMoodleSession([cookie]) else { return nil }
        var properties = cookie.properties ?? [:]
        properties[.expires] = expiry
        properties[.discard] = nil
        return HTTPCookie(properties: properties)
    }

    /// The cookies the browser and the app's shared jar hand each other: secure ones of the hosts
    /// the Moodle sign-in uses, which `MoodleTokenService.signOut()` also purges from that jar.
    static func isSharedCookie(_ cookie: HTTPCookie) -> Bool {
        guard cookie.isSecure else { return false }
        return ["ntust.edu.tw", ssoHost, moodleHost].contains(String(cookie.domain.lowercased().trimmingPrefix(".")))
    }

    /// The hidden sign-in page has failed once SSO or Moodle asks for a password.
    static func endsSessionSignIn(_ url: URL) -> Bool {
        if isMoodleSignInPage(url) { return true }
        if host(of: url) == ssoHost, segments(of: url).starts(with: ["account", "login"]) { return true }
        return !isAllowed(url)
    }

    private static func host(of url: URL) -> String? {
        guard let host = url.host(percentEncoded: false)?.lowercased() else { return nil }
        return host.hasSuffix(".") ? String(host.dropLast()) : host
    }

    private static func segments(of url: URL) -> [String] {
        var segments: [String] = []
        for part in url.path(percentEncoded: false).split(separator: "/") {
            switch part {
            case ".": continue
            case "..": _ = segments.popLast()
            default: segments.append(part.lowercased())
            }
        }
        return segments
    }
}
