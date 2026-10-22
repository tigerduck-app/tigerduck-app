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

    private(set) var generation = 0

    let cookieStorage: HTTPCookieStorage = HTTPCookieStorage
        .sharedCookieStorage(forGroupContainerIdentifier: "group.org.ntust.app.TigerDuck")

    private static let cookieTTL: TimeInterval = 3600

    var cookiesValid: Bool {
        guard let timestamp = Defaults[.ssoLoginTimestamp] else {
            return false
        }
        return Date().timeIntervalSince1970 - timestamp < Self.cookieTTL
    }

    func probeCookiesValid() async -> Bool {
        await probeCookiesValid(using: session)
    }

    func probeCookiesValid(using session: URLSession) async -> Bool {
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
            if valid {
                Defaults[.ssoLoginTimestamp] = Date().timeIntervalSince1970
            }
            return valid
        } catch {
            return false
        }
    }

    private init() {
        for cookie in cookieStorage.cookies ?? [] where !Self.isSSOCookie(cookie) {
            cookieStorage.deleteCookie(cookie)
        }
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = cookieStorage
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
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
        for cookie in cookieStorage.cookies ?? []
        where cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == url.host {
            cookieStorage.deleteCookie(cookie)
        }
    }

    func markLoginSuccess() {
        Defaults[.ssoLoginTimestamp] = Date().timeIntervalSince1970
    }

    func invalidateSession() {
        generation &+= 1
        Self.cancelTasks(of: session, thenEmpty: cookieStorage)
        Defaults[.ssoLoginTimestamp] = nil
    }

    nonisolated static func cancelTasks(of session: URLSession, thenEmpty jar: HTTPCookieStorage) {
        jar.cookies?.forEach { jar.deleteCookie($0) }
        session.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
            jar.cookies?.forEach { jar.deleteCookie($0) }
        }
    }
}

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
