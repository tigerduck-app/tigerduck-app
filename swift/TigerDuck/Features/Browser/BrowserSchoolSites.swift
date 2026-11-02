import Foundation

/// What the browser does for the school sites that SSO's redirect alone does not sign in, or
/// that a signed-in session breaks.
nonisolated enum BrowserSchoolSites {
    /// The school's IIS answers 400 to a request whose headers pass 16 KB, http.sys's default
    /// `MaxRequestBytes`. The apps that share a host, as stuinfosys's do, each keep a 4 KB
    /// session on the host's whole path, so a third one signed in breaks them all. Past half that,
    /// a page opens with its host's cookies gone and signs in again through SSO, whose session is
    /// on `.ntust.edu.tw`.
    static let cookieBudget = 8 * 1024

    /// The cookies of `url`'s own host, when all the cookies the browser would send it pass
    /// ``cookieBudget``.
    static func cookiesToDrop(from cookies: [HTTPCookie], opening url: URL) -> [HTTPCookie] {
        guard let host = BrowserRouting.host(of: url) else { return [] }
        let path = url.path(percentEncoded: true)
        let sent = cookies.filter { isSent($0, to: host, path: path.isEmpty ? "/" : path) }
        let size = sent.reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count + 2 }
        guard size > cookieBudget else { return [] }
        return sent.filter { $0.domain.lowercased().trimmingPrefix(".") == host }
    }

    /// What the sign-in button of a page that opens signed out loads, for the sites whose landing
    /// page waits for that tap; it goes through SSO and comes back to the site signed in.
    static func signInLink(for url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https", url.query == nil, let host = BrowserRouting.host(of: url) else { return nil }
        switch (host, url.path(percentEncoded: true).lowercased()) {
        case ("querycourse.ntust.edu.tw", "/querycourse/"):
            // The button passes the page it is on, as encodeURIComponent writes it.
            let page = url.absoluteString.addingPercentEncoding(withAllowedCharacters: uriComponent) ?? ""
            return URL(string: "https://querycourse.ntust.edu.tw/QueryCourse/api//OAuth2/Login?returnUrl=" + page)
        case ("sa02.ntust.edu.tw", "/webcounseling/"):
            return URL.knownGood("https://sa02.ntust.edu.tw/WebCounseling/OAuth2/Login")
        case ("sa.ntust.edu.tw", "/dorm/"):
            return URL.knownGood("https://sa.ntust.edu.tw/Dorm/OAuth2/Login")
        default:
            return nil
        }
    }

    /// A sign-in form of a site's own: the names of its student id and password fields, which the
    /// browser fills. Its CAPTCHA and its submit stay the student's.
    struct SignInForm: Equatable {
        let studentId: String
        let password: String
    }

    /// The form the page at `url` signs in with, for the exact https origins and paths listed.
    static func signInForm(at url: URL) -> SignInForm? {
        guard let page = page(of: url) else { return nil }
        return signInForms[page.origin + page.path]
    }

    /// The origin and path a page script compares with `location.origin` and `location.pathname`.
    static func page(of url: URL) -> (origin: String, path: String)? {
        guard url.scheme == "https", url.port == nil, url.user == nil, url.password == nil,
              let host = url.host(percentEncoded: false)?.lowercased() else { return nil }
        return ("https://" + host, url.path(percentEncoded: true))
    }

    private static let signInForms: [String: SignInForm] = [
        "https://stuinfosys.ntust.edu.tw/Authenticate/Account/EnrollStudent/ethicscourse": SignInForm(studentId: "UserName", password: "Password"),
        "https://stuinfosys.ntust.edu.tw/Authenticate/SSOAccount/Index/SSOcgesocial": SignInForm(studentId: "UserName", password: "Password"),
        "https://cardsystem.ntust.edu.tw/std/index.php/user/login": SignInForm(studentId: "id", password: "password"),
        "https://studentpay.ntust.edu.tw/": SignInForm(studentId: "studentno", password: "password"),
    ]

    private static let uriComponent = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")

    private static func isSent(_ cookie: HTTPCookie, to host: String, path: String) -> Bool {
        let domain = cookie.domain.lowercased()
        let matches = domain.trimmingPrefix(".") == host || domain.hasPrefix(".") && host.hasSuffix(domain)
        return matches && path.hasPrefix(cookie.path)
    }
}
