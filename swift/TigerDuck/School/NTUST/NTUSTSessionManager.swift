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

protocol LoadingIndicator: AnyObject {
    var loadingState: LoadingState { get set }
    var loadingStarts: Int { get }
}

extension NTUSTSessionManager: LoadingIndicator {}

@Observable
final class NTUSTSessionManager {
    static let shared = NTUSTSessionManager()

    /// Browser-like User-Agent built from actual OS info so SSO/Moodle sees a
    /// consistent device fingerprint. On Mac we pretend to be an iPhone so
    /// NTUST renders the same mobile-friendly templates the iOS app sees;
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

    var loadingState: LoadingState = .idle {
        didSet { if loadingState == .loading { loadingStarts &+= 1 } }
    }

    private(set) var loadingStarts = 0

    let session: URLSession

    /// The identifier must be an App Group in `TigerDuck.entitlements`. Any other gives a store
    /// kept only in memory, which loses the SSO session on every relaunch.
    let ntustCookieJar: HTTPCookieStorage = HTTPCookieStorage
        .sharedCookieStorage(forGroupContainerIdentifier: "group.org.ntust.app.TigerDuck")

    private static let cookieFreshness = FreshnessPolicy(lifetime: 3600)

    var ssoLoginStampIsFresh: Bool {
        guard let timestamp = Defaults[.ssoLoginTimestamp] else {
            return false
        }
        return Self.cookieFreshness.isFresh(storedAt: Date(timeIntervalSince1970: timestamp))
    }

    /// GET `ssoam2.ntust.edu.tw/` and look for a `302 Location: /Home/Index`, which only happens
    /// while the cookie jar still authenticates the user. Any other response (302 to
    /// `/account/login`, 200 with the login page, a network error) counts as expired.
    func probeCookiesValid(for signIn: SignIn) async -> Bool {
        await probeCookiesValid(using: session, for: signIn)
    }

    func probeCookiesValid(using session: URLSession, for signIn: SignIn) async -> Bool {
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
            if valid { markLoginSuccess(for: signIn) }
            return valid
        } catch {
            return false
        }
    }

    private init() {
        // A service keeps its server session behind a cookie that ends with the app, and a visit
        // with only its persisted sign-in cookie signs the account out of SSO. Dropping those at
        // launch lets the next visit sign the service in again through the SSO session.
        for cookie in ntustCookieJar.cookies ?? [] where !Self.isSSOCookie(cookie) {
            ntustCookieJar.deleteCookie(cookie)
        }
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = ntustCookieJar
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = SchoolSessions.requestTimeout
        config.timeoutIntervalForResource = SchoolSessions.resourceTimeout
        config.httpAdditionalHeaders = [
            "User-Agent": Self.browserUserAgent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-TW,zh;q=0.9",
        ]
        session = URLSession(
            configuration: config,
            delegate: TLSPinningDelegate.shared,
            delegateQueue: nil,
        )
    }

    private static func isSSOCookie(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domain == "ssoam2.ntust.edu.tw" || domain == "ntust.edu.tw"
    }

    func dropServiceCookies(for url: URL) {
        for cookie in ntustCookieJar.cookies ?? []
        where cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == url.host {
            ntustCookieJar.deleteCookie(cookie)
        }
    }

    func markLoginSuccess(for signIn: SignIn) {
        Defaults[.ssoLoginTimestamp, for: signIn] = Date().timeIntervalSince1970
    }

    func cancelTasksAndForgetSignIn() {
        // Flows keep this session, and a request on an invalidated one ends the app with an
        // exception, so its tasks are cancelled instead.
        Self.cancelTasks(of: session, thenEmpty: ntustCookieJar)
        Defaults.reset(.ssoLoginTimestamp)
    }

    nonisolated static func cancelTasks(of session: URLSession, thenEmpty jar: HTTPCookieStorage) {
        empty(jar)
        session.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
            empty(jar)
        }
    }

    private nonisolated static func empty(_ jar: HTTPCookieStorage) {
        jar.cookies?.forEach { jar.deleteCookie($0) }
    }
}

/// Answers the server-trust challenge itself, as `CredentialPostDelegate` does, so the probe keeps
/// the pin check whichever way URLSession routes a task delegate's challenges.
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
