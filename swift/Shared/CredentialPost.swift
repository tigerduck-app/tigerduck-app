import Foundation
import os

nonisolated enum CredentialPost {
    private static let signInHost = "ssoam2.ntust.edu.tw"
    private static let schoolDomain = "ntust.edu.tw"

    static func isSignInTarget(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == signInHost
    }

    static func isSchoolTarget(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == schoolDomain || host.hasSuffix("." + schoolDomain)
    }

    static func schemeLabel(of url: URL) -> String {
        switch url.scheme?.lowercased() {
        case "https": "https"
        case "http": "http"
        default: "other"
        }
    }

    /// The request a redirect of the POST is followed with, or nil to stop at the redirect, which
    /// is then the POST's answer. URLSession sends the form again to the `Location` of a 307 or a
    /// 308, so only a 301, 302 or 303 is followed, as a GET without the form and over HTTPS.
    static func request(following response: HTTPURLResponse, proposed: URLRequest) -> URLRequest? {
        guard [301, 302, 303].contains(response.statusCode),
              proposed.url?.scheme?.lowercased() == "https" else { return nil }
        var get = proposed
        get.httpMethod = "GET"
        get.httpBody = nil
        get.httpBodyStream = nil
        get.setValue(nil, forHTTPHeaderField: "Content-Type")
        get.setValue(nil, forHTTPHeaderField: "Content-Length")
        return get
    }
}

nonisolated final class CredentialPostDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private static let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Auth")

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let next = CredentialPost.request(following: response, proposed: request)
        if next == nil {
            Self.logger.error(
                "Sign-in POST stopped at a \(response.statusCode, privacy: .public) redirect to \(request.url?.host ?? "", privacy: .private)"
            )
        }
        completionHandler(next)
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
