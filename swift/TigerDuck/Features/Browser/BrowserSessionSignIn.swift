import UIKit
import WebKit

/// Signs the browser in to a school site with the school SSO session the app already holds, for
/// when Moodle has no autologin key to give or another school site sends the browser to SSO's
/// password form: the app's sign-in cookies for that site go into the browser, a hidden page runs
/// the site's SSO entry, and the sign-in cookies it ends with go back. For a site other than
/// Moodle the app first renews its own SSO session where it lapsed, as a school fetch does; no
/// password goes into a page.
@MainActor
struct BrowserSessionSignIn {
    var putCookie: (HTTPCookie) async -> Void
    var browserCookies: () async -> [HTTPCookie]
    /// Runs `entry` on the hidden page; true once it passed SSO on its way to `target`.
    var runPage: (_ entry: URL, _ target: URL) async -> Bool
    /// Whether the app's SSO session is live, renewed first where it lapsed.
    var renewSession: (SignIn) async -> Bool
    var appJars: () -> [[HTTPCookie]] = { [HTTPCookieStorage.shared, SchoolWeb.schoolCookies].map { $0.cookies ?? [] } }
    var keepCookie: (HTTPCookie) -> Void = { HTTPCookieStorage.shared.setCookie($0) }
    var storeResets: () -> Int = { BrowserData.shared.storeResets }

    func signIn(for signIn: SignIn, to target: URL) async -> Bool {
        guard !signIn.isDemo else { return false }
        let resets = storeResets()
        // A sign-out or a Settings › Storage reset since the start purged the jars, which must not
        // get the cookies they held back, nor the browser's store those it held.
        let isCurrent = { !Task.isCancelled && signIn.isCurrent && storeResets() == resets }
        if !BrowserRouting.isMoodleReturnPage(target) {
            guard await renewSession(signIn), isCurrent() else { return false }
        }
        for cookie in Self.sessionCookies(in: appJars(), for: target) {
            guard isCurrent() else { return false }
            await putCookie(cookie)
        }
        guard isCurrent(), await runPage(BrowserRouting.signInEntry(for: target), target) else { return false }
        let signedIn = await browserCookies()
        guard isCurrent() else { return false }
        signedIn.filter { BrowserRouting.isSignInCookie($0, for: target) }.forEach(keepCookie)
        return !BrowserRouting.isMoodleReturnPage(target) || BrowserRouting.hasMoodleSession(signedIn)
    }

    /// The jars' sign-in cookies for `target` in the order they go into the browser. A later cookie
    /// replaces one of the same name, domain and path, so the school jar, whose session
    /// `NTUSTSessionManager` keeps alive, comes after the shared one, which holds what the last
    /// Moodle token harvest left.
    nonisolated static func sessionCookies(in jars: [[HTTPCookie]], for target: URL) -> [HTTPCookie] {
        jars.joined().filter { BrowserRouting.isSignInCookie($0, for: target) }
    }
}

extension BrowserSessionSignIn {
    /// `host` holds the hidden page under the visible one, as WebKit runs a page off screen slowly.
    /// Without `auth` the jars go in as they are.
    init(store: WKWebsiteDataStore, host: UIView?, auth: AuthService?) {
        self.init(
            putCookie: { await store.httpCookieStore.setCookie($0) },
            browserCookies: { await store.httpCookieStore.allCookies() },
            runPage: { [weak host] entry, target in
                await BrowserSignInPage(store: store, host: host, target: target).run(entry)
            },
            renewSession: { signIn in
                guard let auth else { return true }
                return await auth.ensureAuthenticated(for: signIn)
            }
        )
    }
}

/// What the hidden page's navigations mean for a sign-in to `target`, apart from WebKit.
nonisolated struct BrowserSignInSteps {
    enum Step: Equatable { case allow, fail }

    let target: URL
    private var throughSSO = false

    init(target: URL) {
        self.target = target
    }

    /// A logout anywhere fails the sign-in, as does a main-frame password form, reCAPTCHA or
    /// another site.
    mutating func navigating(to url: URL, isMainFrame: Bool) -> Step {
        if BrowserRouting.isLogout(url) { return .fail }
        guard isMainFrame else { return .allow }
        if BrowserRouting.endsSessionSignIn(url) { return .fail }
        if BrowserRouting.host(of: url) == BrowserRouting.ssoHost { throughSSO = true }
        return .allow
    }

    /// A school site's first page may send the browser to SSO by a script or a refresh, so the
    /// sign-in ends at a school page only once it went through ssoam2.
    func isSignedIn(at url: URL) -> Bool {
        guard !BrowserRouting.isMoodleReturnPage(target) else { return BrowserRouting.isMoodleReturnPage(url) }
        return throughSSO && BrowserRouting.isSchoolReturnPage(url)
    }
}

/// The hidden page a session sign-in runs in, with the visible browser's logout rule list: a
/// page's own request to a logout would end the SSO session the app holds.
@MainActor
private final class BrowserSignInPage: NSObject, WKNavigationDelegate {
    private let store: WKWebsiteDataStore
    private weak var host: UIView?
    private var steps: BrowserSignInSteps
    private var finish: ((Bool) -> Void)?

    static let deadline: Duration = .seconds(15)

    init(store: WKWebsiteDataStore, host: UIView?, target: URL) {
        self.store = store
        self.host = host
        steps = BrowserSignInSteps(target: target)
    }

    func run(_ entry: URL) async -> Bool {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        await BrowserPageScripts.addLogoutRules(to: configuration.userContentController)
        let page = WKWebView(frame: host?.bounds ?? .zero, configuration: configuration)
        page.navigationDelegate = self
        page.isUserInteractionEnabled = false
        host?.insertSubview(page, at: 0)
        defer {
            page.stopLoading()
            page.removeFromSuperview()
        }
        let deadline = Task {
            try? await AppClock.sleep(until: ContinuousClock.now + Self.deadline)
            finish?(false)
        }
        defer { deadline.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                finish = { [weak self] signedIn in
                    self?.finish = nil
                    continuation.resume(returning: signedIn)
                }
                page.load(URLRequest(url: entry))
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
        guard steps.navigating(to: url, isMainFrame: action.targetFrame?.isMainFrame != false) == .allow else {
            decisionHandler(.cancel)
            finish?(false)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // The SSO's form_post page finishes too, on its way back to the site.
        if let url = webView.url, steps.isSignedIn(at: url) { finish?(true) }
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
