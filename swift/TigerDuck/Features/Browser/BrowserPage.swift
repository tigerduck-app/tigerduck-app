import UIKit
import WebKit

/// What the browser's chrome shows of its page, and the actions it takes on it.
@MainActor
@Observable
final class BrowserPage {
    enum Failure: Equatable {
        case certificate(host: String)
        case unreachable(host: String)
    }

    fileprivate(set) var url: URL?
    fileprivate(set) var title = ""
    fileprivate(set) var canGoBack = false
    fileprivate(set) var canGoForward = false
    fileprivate(set) var isLoading = false
    fileprivate(set) var isCollapsed = false
    var failure: Failure?
    var outside: URL?
    /// The page the browser opened with, which the bars name until a page commits.
    fileprivate(set) var start: URL?

    let signIn: BrowserSignIn
    let find = BrowserFind()
    fileprivate(set) var zoom = BrowserZoom.standard
    fileprivate(set) var isDesktopSite = false
    let store: WKWebsiteDataStore
    let generation: Int
    @ObservationIgnored fileprivate weak var webView: WKWebView?
    @ObservationIgnored private var collapse = BrowserChromeCollapse()

    init() {
        let data = BrowserData.shared
        let store = data.store
        self.store = store
        generation = data.generation
        signIn = BrowserSignIn(
            hasSession: { BrowserRouting.hasMoodleSession(await store.httpCookieStore.allCookies()) },
            signedInURL: { target in
                let url = await MoodleAutologinService.shared.url(for: target)
                return url == target ? nil : url
            }
        )
    }

    /// The address the bars, the sheet, Copy and Share go by: a one-time sign-in link stands for
    /// the page it signs in to, as its key must never leave the browser.
    var address: URL? {
        guard let shown = url ?? start else { return nil }
        return BrowserRouting.isMoodleSignInLink(shown) ? signIn.target ?? AppConstants.moodleBaseURL : shown
    }

    var host: String { address?.host(percentEncoded: false) ?? "" }

    var serverTrust: SecTrust? { webView?.serverTrust }

    enum Connection { case secure, refused, unknown }

    /// Only a page that loaded over a trusted connection is called secure.
    var connection: Connection { Self.connection(failure: failure, hasTrust: serverTrust != nil) }

    static func connection(failure: Failure?, hasTrust: Bool) -> Connection {
        switch failure {
        case .certificate: .refused
        case .unreachable: .unknown
        case nil: hasTrust ? .secure : .unknown
        }
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }

    func reloadOrStop() {
        if isLoading {
            webView?.stopLoading()
        } else if failure != nil, let address {
            failure = nil
            webView?.load(URLRequest(url: address))
        } else {
            webView?.reload()
        }
    }

    /// Find and print need a page on screen, not an error or a sign-in under way.
    var canUsePage: Bool { Self.canUsePage(failure: failure, signIn: signIn.phase, url: url) }

    static func canUsePage(failure: Failure?, signIn: BrowserSignIn.Phase, url: URL?) -> Bool {
        failure == nil && signIn == .idle && url != nil
    }

    func zoomIn() { BrowserZoom.larger(than: zoom).map(setZoom) }
    func zoomOut() { BrowserZoom.smaller(than: zoom).map(setZoom) }
    func resetZoom() { setZoom(BrowserZoom.standard) }

    private func setZoom(_ percent: Int) {
        guard !host.isEmpty else { return }
        BrowserSites.stored.setZoom(percent, for: host)
        applySiteSettings()
    }

    /// The page loads again, as its site sends a desktop layout only to a new request.
    func setDesktopSite(_ isDesktop: Bool) {
        guard !host.isEmpty else { return }
        BrowserSites.stored.setDesktop(isDesktop, for: host)
        isDesktopSite = isDesktop
        webView?.reload()
    }

    fileprivate func applySiteSettings() {
        let sites = BrowserSites.stored
        zoom = sites.zoom(for: host)
        isDesktopSite = sites.isDesktop(host)
        webView?.pageZoom = CGFloat(zoom) / 100
    }

    func print() {
        guard let webView else { return }
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = title.isEmpty ? host : title
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printFormatter = webView.viewPrintFormatter()
        controller.present(animated: true)
    }

    func expandChrome() {
        collapse.expand()
        isCollapsed = false
    }

    fileprivate func scrolled(to offset: CGFloat) {
        collapse.scrolled(to: offset)
        if isCollapsed != collapse.isCollapsed { isCollapsed = collapse.isCollapsed }
    }
}

/// The web view's delegate: routes each navigation, turns Moodle's sign-in page into a sign-in,
/// applies the app's TLS pins and keeps ``BrowserPage`` current.
@MainActor
final class BrowserNavigator: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let page: BrowserPage
    private var observations: [NSKeyValueObservation] = []
    private var refusedHosts: Set<String> = []
    /// The Moodle page asked for last, which a sign-in its navigation ran into goes on to.
    private var lastRequested: URL?
    /// How long the store keeps Moodle's session cookie on disk; Moodle's own timeout ends it sooner.
    private static let sessionKept: TimeInterval = 30 * 24 * 60 * 60

    init(page: BrowserPage) {
        self.page = page
    }

    func makeView(opening start: URL) -> UIView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = page.store
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let container = UIView()
        webView.frame = container.bounds
        container.addSubview(webView)
        page.webView = webView
        page.start = start
        observe(webView)

        let store = page.store
        page.signIn.load = { [weak webView] in webView?.load(URLRequest(url: $0)) }
        page.signIn.signInWithSession = { [weak container] in
            await BrowserSessionSignIn(store: store, host: container).signIn()
        }
        page.find.run = { [weak webView] in await webView?.runFind($0) }
        Task {
            await BrowserData.shared.prepare()
            // A sign-in or sign-out has come since this browser opened, and it is closing.
            guard BrowserData.shared.generation == page.generation else { return }
            // Until asked for its records, the store answers with no cookies, not those on disk.
            _ = await store.dataRecords(ofTypes: [WKWebsiteDataTypeCookies])
            await BrowserPageScripts.install(in: configuration.userContentController)
            await page.signIn.open(start)
        }
        return container
    }

    private func observe(_ webView: WKWebView) {
        let page = page
        func track<Value>(_ key: KeyPath<WKWebView, Value>, _ apply: @escaping (WKWebView) -> Void) {
            observations.append(webView.observe(key, options: [.initial]) { view, _ in
                MainActor.assumeIsolated { apply(view) }
            })
        }
        track(\.url) { if page.url != $0.url { page.url = $0.url } }
        track(\.title) { if page.title != $0.title ?? "" { page.title = $0.title ?? "" } }
        track(\.canGoBack) { if page.canGoBack != $0.canGoBack { page.canGoBack = $0.canGoBack } }
        track(\.canGoForward) { if page.canGoForward != $0.canGoForward { page.canGoForward = $0.canGoForward } }
        track(\.isLoading) { if page.isLoading != $0.isLoading { page.isLoading = $0.isLoading } }
        observations.append(webView.scrollView.observe(\.contentOffset) { scrollView, _ in
            MainActor.assumeIsolated {
                guard scrollView.isTracking || scrollView.isDecelerating else { return }
                page.scrolled(to: scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
            }
        })
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        if action.targetFrame?.isMainFrame != false, let host = action.request.url?.host(percentEncoded: false) {
            preferences.preferredContentMode = BrowserSites.stored.isDesktop(host) ? .desktop : .mobile
        }
        decidePolicy(for: action, in: webView) { decisionHandler($0, preferences) }
    }

    private func decidePolicy(
        for action: WKNavigationAction,
        in webView: WKWebView,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if BrowserRouting.isMoodleLogout(url) { return decisionHandler(.cancel) }
        if let frame = action.targetFrame, !frame.isMainFrame { return decisionHandler(.allow) }
        if BrowserRouting.isMoodleSignInPage(url) {
            decisionHandler(.cancel)
            let current = webView.url.flatMap { BrowserRouting.isMoodleReturnPage($0) ? $0 : nil }
            page.signIn.reachedSignInPage(returningTo: lastRequested ?? current ?? AppConstants.moodleBaseURL)
            return
        }
        switch BrowserRouting.decision(for: url, byLinkTap: action.navigationType == .linkActivated) {
        case .load:
            // No target frame means a new window, and the browser has only this one.
            guard action.targetFrame != nil else {
                decisionHandler(.cancel)
                webView.load(action.request)
                return
            }
            if BrowserRouting.isMoodleReturnPage(url) { lastRequested = url }
            page.failure = nil
            decisionHandler(.allow)
        case .openOutside(let outside):
            decisionHandler(.cancel)
            page.outside = outside
        case .handOff(let mail):
            decisionHandler(.cancel)
            UIApplication.shared.open(mail)
        case .refuse:
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        page.applySiteSettings()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        lastRequested = nil
        page.signIn.pageSettled()
        Task { await keepSession() }
        if page.find.isActive { Task { await page.find.search() } }
    }

    private func keepSession() async {
        let cookies = page.store.httpCookieStore
        let expiry = Date.now.addingTimeInterval(Self.sessionKept)
        let lasting = await cookies.allCookies().compactMap { BrowserRouting.lastingSession($0, until: expiry) }
        // A sign-in or sign-out since has emptied this store for the departing account.
        guard BrowserData.shared.generation == page.generation else { return }
        for cookie in lasting { await cookies.setCookie(cookie) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        failed(with: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        failed(with: error)
    }

    private func failed(with error: any Error) {
        guard let failure = Self.failure(for: error, refusedHosts: refusedHosts) else { return }
        page.failure = failure
        page.signIn.pageSettled()
    }

    /// What a failed main-frame load shows; nil for a load the browser itself stopped.
    nonisolated static func failure(for error: any Error, refusedHosts: Set<String>) -> BrowserPage.Failure? {
        let error = error as NSError
        let host = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.host(percentEncoded: false) ?? ""
        if refusedHosts.contains(host) || error.domain == NSURLErrorDomain && (-1206 ... -1200).contains(error.code) {
            return .certificate(host: host)
        }
        // Cancelled, or WebKitErrorFrameLoadInterruptedByPolicyChange after a policy cancel.
        let stopped = (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
            || (error.domain == "WebKitErrorDomain" && error.code == 102)
        return stopped ? nil : .unreachable(host: host)
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let host = challenge.protectionSpace.host
        TLSPinningDelegate.shared.evaluate(challenge) { disposition, credential in
            Task { @MainActor in
                if disposition == .cancelAuthenticationChallenge { self.refusedHosts.insert(host) }
                completionHandler(disposition, credential)
            }
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let address = Self.pageToRestore(url: webView.url, address: page.address) {
            webView.load(URLRequest(url: address))
        } else {
            webView.reload()
        }
    }

    /// What a page whose web content process ended loads, or nil to reload it: a reload does
    /// nothing without a URL, and a one-time sign-in link must not be loaded again.
    nonisolated static func pageToRestore(url: URL?, address: URL?) -> URL? {
        guard let url, !BrowserRouting.isMoodleSignInLink(url) else { return address }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.deny)
    }
}
