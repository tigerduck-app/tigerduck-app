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

    let shown = BrowserShownPage()
    var failure: Failure?
    let certificates = BrowserCertificateCheck()
    var outside: URL?

    let signIn: BrowserSignIn
    let find = BrowserFind()
    let zoomPeek = BrowserZoomPeek()
    private(set) var site = BrowserSiteSetting()
    private let opening: BrowserData.Opening
    let downloads = BrowserDownloads()
    nonisolated static let downloadsRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("BrowserDownloads", isDirectory: true)

    init() {
        opening = BrowserData.shared.opening
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

    var serverTrust: SecTrust? { webView?.serverTrust }

    enum Connection { case secure, refused, unknown }

    /// Only a page that loaded over a trusted connection is called secure, not one the student
    /// opened at their own risk.
    var connection: Connection {
        let trusted = serverTrust.map { !certificates.acceptance.allows(BrowserRiskAcceptance.leaf(of: $0), from: host) }
        return Self.connection(failure: failure, hasTrust: trusted ?? false)
    }

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
        } else if failure != nil, let request = Self.retryRequest(failedDownload: downloads.failed, address: address) {
            failure = nil
            downloads.failed = nil
            webView?.load(request)
        } else {
            webView?.reload()
        }
    }

    /// The host whose refused certificate the student may open anyway.
    var hostToOpenAtRisk: String? {
        guard case .certificate(let host) = failure, certificates.acceptance.canAccept(host: host) else { return nil }
        return host
    }

    /// Accepts the refused certificate for this browser and loads the page again.
    func openAtRisk() {
        guard let host = hostToOpenAtRisk else { return }
        certificates.acceptance.accept(host: host)
        reloadOrStop()
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

    private func setZoom(_ percent: Int) {
        guard !host.isEmpty, let webView else { return }
        BrowserSites.change(for: AccountSession.school.currentSignIn) { $0.setZoom(percent, for: host) }
        BrowserPageScripts.addScripts(to: webView.configuration.userContentController)
        applySiteSettings()
    }

    /// The page loads again, as its site sends a desktop layout only to a new request.
    func setDesktopSite(_ isDesktop: Bool) {
        guard !host.isEmpty else { return }
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

@MainActor
final class BrowserDownloads {
    let opener = MoodleFileOpener()
    nonisolated let folder = BrowserPage.downloadsRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    var failed: URLRequest?

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }
}
