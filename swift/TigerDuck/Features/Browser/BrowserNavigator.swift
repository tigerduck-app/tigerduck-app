import UIKit
import WebKit

@MainActor
@Observable
final class BrowserShownPage {
    fileprivate(set) var url: URL?
    fileprivate(set) var title = ""
    fileprivate(set) var canGoBack = false
    fileprivate(set) var canGoForward = false
    fileprivate(set) var isLoading = false
    fileprivate(set) var progress = 0.0
    fileprivate(set) var isCollapsed = false
    fileprivate(set) var start: URL?
    @ObservationIgnored fileprivate(set) weak var webView: WKWebView?
    @ObservationIgnored private var collapse = BrowserChromeCollapse()

    func expandChrome() {
        collapse.expand()
        isCollapsed = false
    }

    fileprivate func scrolled(to offset: CGFloat) {
        collapse.scrolled(to: offset)
        if isCollapsed != collapse.isCollapsed { isCollapsed = collapse.isCollapsed }
    }
}

@MainActor
final class BrowserNavigator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    private let page: BrowserPage
    private var observations: [NSKeyValueObservation] = []
    private var refusedHosts: Set<String> = []
    private var saving: [ObjectIdentifier: (file: URL, mimeType: String?)] = [:]
    private var lastRequested: URL?
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
        page.shown.webView = webView
        page.shown.start = start
        observe(webView)

        let store = page.store
        page.signIn.load = { [weak webView] in webView?.load(URLRequest(url: $0)) }
        page.signIn.signInWithSession = { [weak container] in
            await BrowserSessionSignIn(store: store, host: container).signIn()
        }
        page.find.run = { [weak webView] in await webView?.runFind($0) }
        Task {
            await BrowserData.shared.prepare()
            guard BrowserData.shared.epoch == page.epoch else { return }
            // Until asked for its records, the store answers with no cookies, not those on disk.
            _ = await store.dataRecords(ofTypes: [WKWebsiteDataTypeCookies])
            await BrowserPageScripts.install(in: configuration.userContentController)
            await page.signIn.open(start)
        }
        return container
    }

    private func observe(_ webView: WKWebView) {
        let shown = page.shown
        func track<Value>(_ key: KeyPath<WKWebView, Value>, _ apply: @escaping (WKWebView) -> Void) {
            observations.append(webView.observe(key, options: [.initial]) { view, _ in
                MainActor.assumeIsolated { apply(view) }
            })
        }
        track(\.url) { if shown.url != $0.url { shown.url = $0.url } }
        track(\.title) { if shown.title != $0.title ?? "" { shown.title = $0.title ?? "" } }
        track(\.canGoBack) { if shown.canGoBack != $0.canGoBack { shown.canGoBack = $0.canGoBack } }
        track(\.canGoForward) { if shown.canGoForward != $0.canGoForward { shown.canGoForward = $0.canGoForward } }
        track(\.isLoading) { if shown.isLoading != $0.isLoading { shown.isLoading = $0.isLoading } }
        track(\.estimatedProgress) { if shown.progress != $0.estimatedProgress { shown.progress = $0.estimatedProgress } }
        observations.append(webView.scrollView.observe(\.contentOffset) { scrollView, _ in
            MainActor.assumeIsolated {
                guard scrollView.isTracking || scrollView.isDecelerating else { return }
                shown.scrolled(to: scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
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
            page.downloads.failed = nil
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

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
        let action = BrowserRouting.responseAction(
            canShow: navigationResponse.canShowMIMEType, contentDisposition: disposition, isMainFrame: navigationResponse.isForMainFrame
        )
        return action == .download ? .download : .allow
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
        page.signIn.pageSettled()
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let folder = page.downloads.folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        let file = folder.appendingPathComponent(MoodleFileDownloads.safeName(suggestedFilename))
        saving[ObjectIdentifier(download)] = (file, response.mimeType)
        return file
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let saved = saving.removeValue(forKey: ObjectIdentifier(download)) else { return }
        page.files.show(downloaded: saved.file, mimeType: saved.mimeType)
    }

    func download(
        _ download: WKDownload,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        decisionHandler: @escaping @MainActor @Sendable (WKDownload.RedirectPolicy) -> Void
    ) {
        decisionHandler(BrowserRouting.allowsDownloadRedirect(to: request.url) ? .allow : .cancel)
    }

    func download(
        _ download: WKDownload,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        pin(challenge, completionHandler: completionHandler)
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        saving[ObjectIdentifier(download)] = nil
        page.downloads.failed = download.originalRequest
        page.failure = .download(
            error, refusedHosts: refusedHosts,
            requestedHost: download.originalRequest?.url?.host(percentEncoded: false) ?? page.host
        )
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
        guard BrowserData.shared.epoch == page.epoch else { return }
        for cookie in lasting { await cookies.setCookie(cookie) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        failed(with: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        failed(with: error)
    }

    private func failed(with error: any Error) {
        guard let failure = BrowserPage.Failure.load(error, refusedHosts: refusedHosts) else { return }
        page.downloads.failed = nil
        page.failure = failure
        page.signIn.pageSettled()
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        pin(challenge, completionHandler: completionHandler)
    }

    private func pin(
        _ challenge: URLAuthenticationChallenge,
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
        if let address = BrowserRouting.pageToRestore(url: webView.url, address: page.address) {
            webView.load(URLRequest(url: address))
        } else {
            webView.reload()
        }
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

extension BrowserPage.Failure {
    nonisolated static func load(_ error: any Error, refusedHosts: Set<String>) -> Self? {
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

    nonisolated static func download(_ error: any Error, refusedHosts: Set<String>, requestedHost: String) -> Self {
        let failure = load(error, refusedHosts: refusedHosts)
        if case .certificate = failure, let failure { return failure }
        return .unreachable(host: requestedHost)
    }
}
