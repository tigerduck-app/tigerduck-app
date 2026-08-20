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

    /// NTUST-only cookie jar. Previously the session shared
    /// `HTTPCookieStorage.shared`, so NTUST SSO cookies leaked into any
    /// other URLSession on the same process (Library, future WKWebViews,
    /// third-party SDKs) that didn't opt out of shared storage. Scope
    /// every NTUST cookie to this private store; logout / explicit
    /// purges only need to touch this jar.
    ///
    /// `sharedCookieStorage(forGroupContainerIdentifier:)` returns a
    /// per-identifier persistent store — distinct from `.shared` and
    /// not visible to it. The identifier is namespaced to this bundle
    /// and does NOT need to match any App Group entitlement; it's just
    /// a key for the storage namespace.
    let cookieStorage: HTTPCookieStorage = HTTPCookieStorage
        .sharedCookieStorage(forGroupContainerIdentifier: "org.ntust.app.TigerDuck.ntust-session")

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

    /// Server-side probe (~30ms warm): GET `ssoam2.ntust.edu.tw/` and
    /// look for a `302 Location: /Home/Index` redirect, which only
    /// happens when the current cookie jar still authenticates the
    /// user. Any other response (302 to `/account/login`, 200 rendering
    /// the login page, network error) counts as expired.
    ///
    /// This is far more accurate than the 1h timestamp TTL — obsoletes
    /// "cookies said fresh but server already evicted them" and
    /// "cookies still valid for hours but local timer flipped at 3600s"
    /// in one shot. Use this from any async auth path instead of
    /// ``cookiesValid``.
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
            // Slide the local TTL forward on a confirmed-good probe so
            // synchronous UI consumers (`cookiesValid`) don't show
            // "not authenticated" merely because the user has been idle
            // longer than the static 1h window while the server still
            // honors the cookie jar.
            if valid {
                Defaults[.ssoLoginTimestamp] = Date().timeIntervalSince1970
            }
            return valid
        } catch {
            return false
        }
    }

    private init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = cookieStorage
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 15
        // Default `timeoutIntervalForResource` is 7 days — far too long
        // for an interactive SSO login. Cap the entire request lifetime
        // at 60 s so a stalled or partially-responsive server cannot
        // wedge a Task forever.
        config.timeoutIntervalForResource = 60
        config.httpAdditionalHeaders = [
            "User-Agent": Self.browserUserAgent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-TW,zh;q=0.9",
        ]
        // SPKI pin against the *.ntust.edu.tw pin set so an MDM-pushed
        // root CA on hostile campus Wi-Fi cannot MITM SSO credentials.
        // The per-task `NoRedirectSessionDelegate` used by
        // `probeCookiesValid()` forwards server-trust challenges to
        // this same `TLSPinningDelegate.shared` explicitly — see the
        // delegate definition below for why we don't rely on
        // URLSession's task→session delegate fallthrough.
        session = URLSession(
            configuration: config,
            delegate: TLSPinningDelegate.shared,
            delegateQueue: nil,
        )
    }

    func markLoginSuccess() {
        Defaults[.ssoLoginTimestamp] = Date().timeIntervalSince1970
    }

    func invalidateSession() {
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

    /// Forward server-trust challenges to the session's pinning
    /// delegate explicitly.
    ///
    /// URLSession's documented behaviour is to fall through to the
    /// session-level delegate for any task-level callback the per-task
    /// delegate doesn't implement — but that's empirically fragile
    /// (Apple has tweaked the rules across iOS versions) and any
    /// future addition of a task-level method here that doesn't also
    /// handle `didReceive challenge` would silently degrade this
    /// pinned-host probe to system trust. Forward explicitly so SPKI
    /// pinning on `ssoam2.ntust.edu.tw` is unconditional regardless of
    /// what other URLSessionTaskDelegate methods get added later.
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
