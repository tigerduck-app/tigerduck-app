import UIKit
import WebKit

/// Signs the browser in with the school SSO session the app already holds, for when Moodle has no
/// autologin key to give: the app's sign-in cookies go into the browser, a hidden page runs
/// Moodle's OIDC entry, and the cookies it ends with go back. No password is posted.
@MainActor
final class BrowserSessionSignIn: NSObject, WKNavigationDelegate {
    private let store: WKWebsiteDataStore
    private weak var host: UIView?
    private var finish: ((Bool) -> Void)?

    static let deadline: Duration = .seconds(15)

    /// `host` holds the hidden page under the visible one, as WebKit runs a page off screen slowly.
    init(store: WKWebsiteDataStore, host: UIView?) {
        self.store = store
        self.host = host
    }

    func signIn() async -> Bool {
        let isCurrent = AccountSession.school.currentCheck()
        let epoch = BrowserData.shared.epoch
        let cookies = store.httpCookieStore
        let jars = [HTTPCookieStorage.shared, NTUSTSessionManager.shared.cookieStorage]
        for cookie in Self.sessionCookies(in: jars.map { $0.cookies ?? [] }) {
            await cookies.setCookie(cookie)
        }
        guard await runSignInPage() else { return false }
        let signedIn = await cookies.allCookies()
        // A sign-out since the start purged the jar, which must not get the departing account's cookies back.
        guard !Task.isCancelled, isCurrent(), BrowserData.shared.epoch == epoch else { return false }
        signedIn.filter(BrowserRouting.isSharedCookie).forEach(HTTPCookieStorage.shared.setCookie)
        return BrowserRouting.hasMoodleSession(signedIn)
    }

    /// The jars' sign-in cookies in the order they go into the browser. A later cookie replaces one
    /// of the same name, domain and path, so the school jar, whose session `NTUSTSessionManager`
    /// keeps alive, comes after the shared one, which holds what the last Moodle token harvest left.
    nonisolated static func sessionCookies(in jars: [[HTTPCookie]]) -> [HTTPCookie] {
        jars.joined().filter(BrowserRouting.isSharedCookie)
    }

    private func runSignInPage() async -> Bool {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let page = WKWebView(frame: host?.bounds ?? .zero, configuration: configuration)
        page.navigationDelegate = self
        page.isUserInteractionEnabled = false
        host?.insertSubview(page, at: 0)
        defer {
            page.stopLoading()
            page.removeFromSuperview()
        }
        let deadline = Task {
            try? await Task.sleep(for: Self.deadline)
            finish?(false)
        }
        defer { deadline.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                finish = { [weak self] signedIn in
                    self?.finish = nil
                    continuation.resume(returning: signedIn)
                }
                page.load(URLRequest(url: BrowserRouting.webSignInURL))
            }
        } onCancel: {
            Task { @MainActor in self.finish?(false) }
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if BrowserRouting.isMoodleLogout(url) { return decisionHandler(.cancel) }
        guard action.targetFrame?.isMainFrame != false, BrowserRouting.endsSessionSignIn(url) else {
            return decisionHandler(.allow)
        }
        decisionHandler(.cancel)
        finish?(false)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // The SSO's form_post page finishes too, on its way back to Moodle.
        if let url = webView.url, BrowserRouting.isMoodleReturnPage(url) { finish?(true) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish?(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish?(false)
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        TLSPinningDelegate.shared.evaluate(challenge) { disposition, credential in
            Task { @MainActor in completionHandler(disposition, credential) }
        }
    }
}
