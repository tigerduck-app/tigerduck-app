import Foundation
import UIKit
import Defaults

enum LoadingState: Equatable {
    case idle
    case loading
    case loaded
    case error(String)
}

@Observable
final class NTUSTSessionManager {
    static let shared = NTUSTSessionManager()

    /// Browser-like User-Agent built from actual device info so SSO/Moodle sees a consistent device fingerprint.
    static let browserUserAgent: String = {
        let osVersion = UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")
        let majorVersion = UIDevice.current.systemVersion.components(separatedBy: ".").first ?? "18"
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(osVersion) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(majorVersion).0 Mobile/15E148 Safari/604.1"
    }()

    var loadingState: LoadingState = .idle

    private(set) var session: URLSession

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
        var req = URLRequest(url: URL(string: "https://ssoam2.ntust.edu.tw/")!)
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
            return location.contains("/Home/Index")
        } catch {
            return false
        }
    }

    private init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = [
            "User-Agent": Self.browserUserAgent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-TW,zh;q=0.9",
        ]
        session = URLSession(configuration: config)
    }

    func markLoginSuccess() {
        Defaults[.ssoLoginTimestamp] = Date().timeIntervalSince1970
    }

    func invalidateSession() {
        HTTPCookieStorage.shared.cookies?.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
        Defaults[.ssoLoginTimestamp] = nil
    }
}

/// Stops URLSession from auto-following 3xx redirects on a single task,
/// so callers can inspect the raw 302 `Location` header (e.g. the
/// ``NTUSTSessionManager.probeCookiesValid()`` /Home/Index signal).
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
}
