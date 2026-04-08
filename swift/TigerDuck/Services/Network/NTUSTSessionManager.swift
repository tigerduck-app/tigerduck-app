import Foundation
import UIKit

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
    private static let timestampKey = "ssoLoginTimestamp"

    var cookiesValid: Bool {
        guard let timestamp = UserDefaults.standard.object(forKey: Self.timestampKey) as? Double else {
            return false
        }
        return Date().timeIntervalSince1970 - timestamp < Self.cookieTTL
    }

    var loginTimestamp: Date? {
        guard let ts = UserDefaults.standard.object(forKey: Self.timestampKey) as? Double else { return nil }
        return Date(timeIntervalSince1970: ts)
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
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.timestampKey)
    }

    func invalidateSession() {
        HTTPCookieStorage.shared.cookies?.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
        UserDefaults.standard.removeObject(forKey: Self.timestampKey)
    }
}
