import Foundation
import os

/// The POST of the school's sign-in form, which carries the password: the SSO sign-in's in
/// `SSOLoginService` and the Moodle token harvest's in `MoodleTokenService`.
nonisolated enum CredentialPost {
    private static let signInHost = "ssoam2.ntust.edu.tw"

    /// Whether the form may post the credentials to `url`: the sign-in host over HTTPS, whatever
    /// the page names as the form's action.
    static func isSignInTarget(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == signInHost
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

/// The task delegate of a credential POST, which follows a redirect only as
/// ``CredentialPost/request(following:proposed:)`` says. Server-trust challenges go to
/// `TLSPinningDelegate.shared`, as `NoRedirectSessionDelegate`'s do; its doc says why.
nonisolated final class CredentialPostDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let next = CredentialPost.request(following: response, proposed: request)
        if next == nil {
            AppLogger.auth.error(
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
