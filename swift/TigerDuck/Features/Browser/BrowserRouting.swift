import Foundation

/// The TigerDuck browser's URL rules: what loads inside, what goes outside, and which school
/// addresses sign the browser in or out. Plain URL checks, so tests need no WebKit.
nonisolated enum BrowserRouting {
    enum Decision: Equatable {
        case load
        /// Off the allowlist: the browser asks before handing it to the system.
        case openOutside(URL)
        /// A `mailto:` link, for the system's mail app.
        case handOff(URL)
        case refuse
    }

    static let moodleHost = AppConstants.moodleBaseURL.host()!.lowercased()
    static let ssoHost = "ssoam2.ntust.edu.tw"
    /// The other SSO host, whose NetIQ form submits through reCAPTCHA.
    static let netIQHost = "ssoam.ntust.edu.tw"
    static let ssoHosts: Set<String> = [ssoHost, netIQHost]

    /// Moodle's OIDC entry, which signs the browser in with the school SSO session it holds.
    static let webSignInURL = URL.knownGood("https://moodle2.ntust.edu.tw/auth/oidc/?source=loginpage")

    enum Restore: Equatable {
        case reload
        case load(URL)
    }

    static func pageToRestore(url: URL?, address: URL?) -> Restore {
        guard let url, !isMoodleSignInLink(url) else { return address.map(Restore.load) ?? .reload }
        return .reload
    }

    /// A download leaves the web view's navigation delegate, so its redirects get the same check here.
    static func allowsDownloadRedirect(to url: URL?) -> Bool {
        url.map { decision(for: $0) == .load } ?? false
    }

    /// `byLinkTap` is whether the student tapped a link: a script's navigation never opens Mail.
    static func decision(for url: URL, byLinkTap: Bool = false) -> Decision {
        switch url.scheme?.lowercased() {
        case "https", "http":
            if isLogout(url) { return .refuse }
            return isAllowed(url) ? .load : .openOutside(url)
        case "about":
            // Pages open about:blank to write into.
            return url.absoluteString.lowercased() == "about:blank" ? .load : .refuse
        case "mailto":
            return byLinkTap ? .handOff(url) : .refuse
        default:
            return .refuse
        }
    }

    enum ResponseAction: Equatable {
        case show
        case download
    }

    /// A page's response WebKit cannot show, or one its server sends as an attachment, is a file
    /// to save. A frame's is left to WebKit, as the browser shows only the page's own files.
    static func responseAction(canShow: Bool, contentDisposition: String?, isMainFrame: Bool) -> ResponseAction {
        guard isMainFrame else { return .show }
        let disposition = contentDisposition?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        return canShow && disposition != "attachment" ? .show : .download
    }

    /// https on the default port with no user in the address, on a subdomain of ntust.edu.tw.
    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, let host = host(of: url) else { return false }
        return host.hasSuffix(".ntust.edu.tw")
    }

    /// Every school site's logout, Moodle's and the others'. Each session is TigerDuck's to end, at
    /// its own sign-out: a logout inside the browser could end the SSO session the app holds.
    static func isLogout(_ url: URL) -> Bool {
        isMoodleLogout(url) || isSchoolLogout(url)
    }

    /// Moodle's logout and auth_oidc's, as the server reads the path: any case, encoding, doubled
    /// slash, dot segment or trailing path. The session is TigerDuck's to end at its own sign-out.
    static func isMoodleLogout(_ url: URL) -> Bool {
        guard host(of: url) == moodleHost else { return false }
        let path = segments(of: url)
        return path.starts(with: ["login", "logout.php"]) || path.starts(with: ["auth", "oidc", "logout.php"])
    }

    /// A logout on `ntust.edu.tw` or a host under it but Moodle's, read as the server reads it: a
    /// path segment whose route ends in a logout word (`Logout.aspx`, `LogOff`, `AGLogout`,
    /// `sign-out`, `logout;jsessionid=x`), SSO's `endsession`, or a query that names the action
    /// (`?action=logout`). A document named so (`logout.pdf`) is no logout.
    static func isSchoolLogout(_ url: URL) -> Bool {
        guard let host = host(of: url), host == "ntust.edu.tw" || host.hasSuffix(".ntust.edu.tw"), host != moodleHost else {
            return false
        }
        let routes = segments(of: url).map(routeName)
        if routes.contains(where: { route in route == "endsession" || !route.isEmpty && logoutWords.contains { route.hasSuffix($0) } }) {
            return true
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return query.contains { actionParameters.contains($0.name.lowercased()) && logoutWords.contains(letters($0.value ?? "")) }
    }

    /// What a school logout's route ends in, letters only.
    static let logoutWords = ["logout", "logoff", "signout"]

    /// The extensions of pages a server runs, which name a route rather than a document.
    static let scriptExtensions = ["aspx", "asp", "ashx", "php", "jsp", "jspx", "do", "action", "cgi", "pl", "cfm", "html", "htm", "shtml"]

    private static let actionParameters: Set<String> = ["action", "act", "op", "cmd", "do", "mode", "method", "task", "func"]

    /// What a server routes `segment` by, letters only: its path parameters and a script's
    /// extension left out. Another extension names a document, which is no route: empty.
    private static func routeName(_ segment: String) -> String {
        let path = segment.prefix { $0 != ";" }
        guard let dot = path.lastIndex(of: "."), dot != path.startIndex else { return letters(path) }
        return scriptExtensions.contains(path[path.index(after: dot)...].lowercased()) ? letters(path[..<dot]) : ""
    }

    private static func letters(_ text: some StringProtocol) -> String {
        String(text.lowercased().filter(\.isLetter))
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

    /// A school page off Moodle and SSO that the school sign-in can return to; it signs in through
    /// the site's own redirect to SSO.
    static func isSchoolReturnPage(_ url: URL) -> Bool {
        guard isAllowed(url), let host = host(of: url), host != moodleHost, !ssoHosts.contains(host) else { return false }
        return !isSchoolLogout(url)
    }

    static func isReturnPage(_ url: URL) -> Bool {
        isMoodleReturnPage(url) || isSchoolReturnPage(url)
    }

    /// SSO's password form, where a school site with no session of its own sends the browser.
    static func isSSOSignInPage(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && host(of: url) == ssoHost && segments(of: url).starts(with: ["account", "login"])
    }

    /// The page a sign-in page at `url` came in the way of, from `pages`, the last one asked for
    /// and the one shown: a Moodle page or Moodle's front page for Moodle's form, any school page
    /// for SSO's. Nil for any other page, and for SSO's form reached from no school page.
    static func signInReturn(for url: URL, among pages: [URL?]) -> URL? {
        if isMoodleSignInPage(url) { return pages.compactMap { $0 }.first(where: isMoodleReturnPage) ?? AppConstants.moodleBaseURL }
        return isSSOSignInPage(url) ? pages.compactMap { $0 }.first(where: isReturnPage) : nil
    }

    /// Where the hidden sign-in for `target` starts: Moodle's OIDC entry, or a school page itself,
    /// which sends the browser through SSO.
    static func signInEntry(for target: URL) -> URL {
        isMoodleReturnPage(target) ? webSignInURL : target
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
        return ["ntust.edu.tw", ssoHost, moodleHost].contains(cookieDomain(cookie))
    }

    /// The shared cookies a sign-in to `target` hands the browser and takes back: all of them for
    /// Moodle's, SSO's for another school site's, never Moodle's. ssoam2 sets its session,
    /// `AuthServer`, on `.ntust.edu.tw` rather than its own host, and skips its form on that alone.
    static func isSignInCookie(_ cookie: HTTPCookie, for target: URL) -> Bool {
        isSharedCookie(cookie) && (isMoodleReturnPage(target) || cookieDomain(cookie) != moodleHost)
    }

    private static func cookieDomain(_ cookie: HTTPCookie) -> String {
        String(cookie.domain.lowercased().trimmingPrefix("."))
    }

    /// The hidden sign-in page has failed once SSO or Moodle asks for a password, or ssoam for its
    /// reCAPTCHA form; the student signs in there.
    static func endsSessionSignIn(_ url: URL) -> Bool {
        if isMoodleSignInPage(url) || isSSOSignInPage(url) { return true }
        if host(of: url) == netIQHost { return true }
        return !isAllowed(url)
    }

    static func host(of url: URL) -> String? {
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
