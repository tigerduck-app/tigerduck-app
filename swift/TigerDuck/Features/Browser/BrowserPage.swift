import UIKit
import WebKit

/// What the browser's chrome shows of its page, and the actions it takes on it.
@MainActor
@Observable
final class BrowserPage {
    enum Failure: Equatable {
        /// With the page the student may open at risk, once the refused leaf is known.
        case certificate(host: String, refusal: BrowserRiskAcceptance.Refusal? = nil)
        case unreachable(host: String)
    }

    let shown = BrowserShownPage()
    var failure: Failure?
    private(set) var certificates = BrowserCertificateCheck()
    var outside: URL?

    let signIn: BrowserSignIn
    let find = BrowserFind()
    let zoomPeek = BrowserZoomPeek()
    private(set) var site = BrowserSiteSetting()
    private var opening: BrowserData.Opening
    let downloads: BrowserDownloads
    nonisolated static let downloadsRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("BrowserDownloads", isDirectory: true)

    init(downloads: BrowserDownloads = BrowserDownloads()) {
        self.downloads = downloads
        let opening = BrowserData.shared.opening
        self.opening = opening
        let store = opening.store
        signIn = BrowserSignIn(
            hasSession: { BrowserRouting.hasMoodleSession(await store.httpCookieStore.allCookies()) },
            signedInURL: { target in
                let url = await SchoolWeb.signedIn(target)
                return url == target ? nil : url
            }
        )
    }

    var store: WKWebsiteDataStore { opening.store }
    var storeResets: Int { opening.resets }
    var url: URL? { shown.url }
    var title: String { shown.title }
    var canGoBack: Bool { shown.canGoBack }
    var canGoForward: Bool { shown.canGoForward }
    var isLoading: Bool { shown.isLoading }
    var progress: Double { shown.progress }
    var isCollapsed: Bool { shown.isCollapsed }
    var files: MoodleFileOpener { downloads.opener }
    var zoom: Int { site.zoom }
    var isDesktopSite: Bool { site.isDesktop }
    private var webView: WKWebView? { shown.webView }

    /// The address the bars, the sheet, Copy and Share go by: a one-time sign-in link stands for
    /// the page it signs in to, as its key must never leave the browser.
    var address: URL? {
        guard let shown = url ?? self.shown.start else { return nil }
        return BrowserRouting.isMoodleSignInLink(shown) ? signIn.target ?? AppConstants.moodleBaseURL : shown
    }

    var host: String { address?.host(percentEncoded: false) ?? "" }

    var sheetAddress: URL? { refusalToOpenAtRisk?.pageToOpen ?? address }

    var openedAtRisk: URL? { opening.openedAtRisk }
    var isAtRisk: Bool { openedAtRisk != nil }

    var serverTrust: SecTrust? { webView?.serverTrust }

    enum Connection { case secure, refused, unknown }

    /// Only a page that loaded over a trusted connection is called secure, and none in a browser
    /// the student opened a page in at their own risk.
    var connection: Connection { Self.connection(failure: failure, hasTrust: serverTrust != nil, isAtRisk: isAtRisk) }

    static func connection(failure: Failure?, hasTrust: Bool, isAtRisk: Bool = false) -> Connection {
        switch failure {
        case .certificate: .refused
        case .unreachable: .unknown
        case nil: hasTrust && !isAtRisk ? .secure : .unknown
        }
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }

    func reloadOrStop() {
        if isLoading {
            webView?.stopLoading()
        } else if failure != nil, let request = Self.retryRequest(failedDownload: downloads.failed, address: address) {
            failure = nil
            downloads.failed = nil
            webView?.load(request)
        } else {
            webView?.reload()
        }
    }

    var refusalToOpenAtRisk: BrowserRiskAcceptance.Refusal? {
        guard case .certificate(_, let refusal?) = failure else { return nil }
        return refusal
    }

    /// Opens the refused page again, its leaf let through, in a new store that starts empty, keeps
    /// nothing on disk and goes with this browser. The browser stays in that store, wherever the
    /// page leads, and no sign-in runs in it again; `TigerDuckBrowserView` builds a web view on it.
    func openAtRisk() {
        guard let refusal = refusalToOpenAtRisk else { return }
        signIn.close()
        certificates = certificates.accepting(refusal)
        opening = BrowserData.Opening(store: .nonPersistent(), resets: opening.resets, openedAtRisk: refusal.pageToOpen)
        failure = nil
        downloads.failed = nil
    }

    func retryDownload(_ item: BrowserDownloads.Item) {
        guard let request = item.request else { return }
        downloads.forget(item.id)
        failure = nil
        downloads.failed = nil
        webView?.load(request)
    }

    /// A download never commits as a page, so the address still names the page it started from.
    static func retryRequest(failedDownload: URLRequest?, address: URL?) -> URLRequest? {
        failedDownload ?? address.map { URLRequest(url: $0) }
    }

    /// Find and print need a page on screen, not an error or a sign-in under way.
    var canUsePage: Bool { Self.canUsePage(failure: failure, signIn: signIn.phase, url: url) }

    static func canUsePage(failure: Failure?, signIn: BrowserSignIn.Phase, url: URL?) -> Bool {
        failure == nil && signIn == .idle && url != nil
    }

    func zoomIn() { BrowserZoom.larger(than: zoom).map(setZoom) }
    func zoomOut() { BrowserZoom.smaller(than: zoom).map(setZoom) }
    func resetZoom() { setZoom(BrowserZoom.standard) }

    /// A page opened at risk keeps its host's saved zoom and desktop choice, which outlive its store.
    private func setZoom(_ percent: Int) {
        guard !host.isEmpty, !isAtRisk, let webView else { return }
        BrowserSites.change(for: AccountSession.school.currentSignIn) { $0.setZoom(percent, for: host) }
        BrowserPageScripts.addScripts(to: webView.configuration.userContentController)
        applySiteSettings()
    }

    /// The page loads again, as its site sends a desktop layout only to a new request.
    func setDesktopSite(_ isDesktop: Bool) {
        guard !host.isEmpty, !isAtRisk else { return }
        BrowserSites.change(for: AccountSession.school.currentSignIn) { $0.setDesktop(isDesktop, for: host) }
        site.isDesktop = isDesktop
        webView?.reload()
    }

    func applySiteSettings() {
        let sites = BrowserSites.stored
        site = BrowserSiteSetting(zoom: sites.zoom(for: host), isDesktop: sites.isDesktop(host))
        // A page back from the history cache keeps the zoom it was left with.
        webView?.evaluateJavaScript(BrowserPageScripts.zoom(sites.zoom))
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

    func expandChrome() { shown.expandChrome() }
}
