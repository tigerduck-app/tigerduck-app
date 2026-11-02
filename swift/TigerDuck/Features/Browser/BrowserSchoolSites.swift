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

    private static func isSent(_ cookie: HTTPCookie, to host: String, path: String) -> Bool {
        let domain = cookie.domain.lowercased()
        let matches = domain.trimmingPrefix(".") == host || domain.hasPrefix(".") && host.hasSuffix(domain)
        return matches && path.hasPrefix(cookie.path)
    }
}
