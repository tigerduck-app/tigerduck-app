import Foundation
import Defaults
#if os(iOS)
import UIKit
#endif

enum LoadingState: Equatable {
    case idle
    case loading
    case loaded
    case error(String)
}

@Observable
final class NTUSTSessionManager {
    static let shared = NTUSTSessionManager()

    /// Browser-like User-Agent built from actual OS info so SSO/Moodle sees a
    /// consistent device fingerprint. On Mac we pretend to be an iPhone so
    /// NTUST renders the same mobile-friendly templates Sam's iOS app sees;
    /// the SSO and Moodle endpoints already serve those layouts everywhere.
    static let browserUserAgent: String = {
        #if os(iOS)
        let osVersion = UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")
        let majorVersion = UIDevice.current.systemVersion.components(separatedBy: ".").first ?? "18"
        #else
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(v.majorVersion)_\(v.minorVersion)_\(v.patchVersion)"
        let majorVersion = "\(v.majorVersion)"
        #endif
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(osVersion) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(majorVersion).0 Mobile/15E148 Safari/604.1"
    }()

    var loadingState: LoadingState = .idle

    private(set) var session: URLSession

    /// NTUST-only cookie jar. In `HTTPCookieStorage.shared`, NTUST SSO cookies would leak into
    /// every other URLSession in the process that does not opt out of shared storage (Library,
    /// WKWebViews, third-party SDKs). Every NTUST cookie lives here, so logout and explicit
    /// purges need only touch this jar.
    ///
    /// The identifier must be an App Group in `TigerDuck.entitlements`. Any other gives a store
    /// kept only in memory, which loses the SSO session on every relaunch.
    let cookieStorage: HTTPCookieStorage = HTTPCookieStorage
        .sharedCookieStorage(forGroupContainerIdentifier: "group.org.ntust.app.TigerDuck")

    private static let cookieTTL: TimeInterval = 3600 // 1 hour

    /// Legacy timestamp-based check — retained for synchronous UI
    /// surfaces (Settings "last login" display, `@Observable` computed
    /// properties that cannot `await`). Auth flows should prefer
    /// ``probeCookiesValid()`` which asks the server directly.
    var cookiesValid: Bool {
        guard let timestamp = Defaults[.ssoLoginTimestamp] else {
            return false
        }
        return Date().timeIntervalSince1970 - timestamp < Self.cookieTTL
    }

    var loginTimestamp: Date? {
        guard let ts = Defaults[.ssoLoginTimestamp] else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    /// Server-side probe (~30ms warm): GET `ssoam2.ntust.edu.tw/` and look for a
    /// `302 Location: /Home/Index`, which only happens while the cookie jar still
    /// authenticates the user. Any other response (302 to `/account/login`, 200 with
    /// the login page, a network error) counts as expired.
    ///
    /// Use this from any async auth path instead of ``cookiesValid``: the 1h timestamp
    /// TTL trusts cookies the server already evicted and expires ones it still honors.
    func probeCookiesValid() async -> Bool {
        var req = URLRequest(url: URL.knownGood("https://ssoam2.ntust.edu.tw/"))
        req.httpMethod = "GET"
        req.timeoutInterval = 8
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        do {
            let (_, response) = try await session.data(
                for: req,
                delegate: NoRedirectSessionDelegate(),
            )
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 302,
                  let location = http.value(forHTTPHeaderField: "Location") else {
                return false
            }
            let valid = location.contains("/Home/Index")
            // A confirmed-good probe slides the local TTL forward, so synchronous UI that
            // reads `cookiesValid` does not show "not authenticated" after an idle hour
            // while the server still honors the cookie jar.
            if valid {
                Defaults[.ssoLoginTimestamp] = Date().timeIntervalSince1970
            }
            return valid
        } catch {
            return false
        }
    }

    private init() {
        session = Self.makeSession(cookieStorage: cookieStorage)
    }

    private static func makeSession(cookieStorage: HTTPCookieStorage) -> URLSession {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = cookieStorage
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 15
        // The default `timeoutIntervalForResource` is 7 days, far too long for an interactive
        // SSO login. Capping the whole request at 60 s keeps a stalled or partly responsive
        // server from wedging a Task forever.
        config.timeoutIntervalForResource = 60
        config.httpAdditionalHeaders = [
            "User-Agent": Self.browserUserAgent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-TW,zh;q=0.9",
        ]
        // SPKI pin against the *.ntust.edu.tw set, so an MDM-pushed root CA on hostile campus
        // Wi-Fi cannot MITM SSO credentials. `NoRedirectSessionDelegate`, the per-task delegate
        // of `probeCookiesValid()`, forwards trust challenges here explicitly; its doc says why.
        return URLSession(
            configuration: config,
            delegate: TLSPinningDelegate.shared,
            delegateQueue: nil,
        )
    }

    func markLoginSuccess() {
        Defaults[.ssoLoginTimestamp] = Date().timeIntervalSince1970
    }

    func invalidateSession() {
        // A login or request still running for the departing account would put its cookies
        // back after the purge below, and the next login would find that session signed in.
        session.invalidateAndCancel()
        session = Self.makeSession(cookieStorage: cookieStorage)
        // Cookies live in the NTUST-only jar now; clear it wholesale —
        // no host-filter tip-toeing required, and Moodle / Library /
        // WebView state in `HTTPCookieStorage.shared` is untouched.
        cookieStorage.cookies?.forEach { cookieStorage.deleteCookie($0) }
        Defaults[.ssoLoginTimestamp] = nil
    }
}

/// Stops URLSession from auto-following 3xx redirects on a single task,
/// so callers can inspect the raw 302 `Location` header (e.g. the
/// ``NTUSTSessionManager.probeCookiesValid()`` /Home/Index signal).
///
/// Also forwards server-trust challenges to ``TLSPinningDelegate.shared``
/// — see the auth-challenge method below.
private final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    /// Forward server-trust challenges to the session's pinning delegate explicitly.
    ///
    /// URLSession documents a fallthrough to the session delegate for task callbacks the
    /// per-task delegate does not implement, but that is fragile in practice: Apple has
    /// changed the rules across iOS versions, and a task-level method added here without
    /// `didReceive challenge` would silently drop this probe to system trust. Forwarding
    /// keeps SPKI pinning on `ssoam2.ntust.edu.tw` unconditional, whatever task delegate
    /// methods get added later.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        TLSPinningDelegate.shared.urlSession(
            session,
            didReceive: challenge,
            completionHandler: completionHandler,
        )
    }
}
