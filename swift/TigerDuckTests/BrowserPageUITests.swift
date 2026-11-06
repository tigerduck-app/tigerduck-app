#if os(iOS)
import Testing
import UIKit
import WebKit
@testable import TigerDuck

/// Listed in `on_screen_tests` in `.github/workflows/tests.yaml`.
@MainActor
@Suite(.serialized)
struct BrowserPageUITests {
    typealias Screen = TLSPinPromptTests.Screen

    private static let site = URL(string: "https://dialog-test.ntust.edu.tw/form")!
    private static var ok: String { String(localized: "browser_dialog_ok") }
    private static var cancel: String { String(localized: "action_cancel") }

    private static func webView(_ pageUI: BrowserPageUI, configuration: WKWebViewConfiguration) -> WKWebView {
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 812), configuration: configuration)
        webView.uiDelegate = pageUI
        return webView
    }

    @Test("a window the page opens goes to this page by the browser's rules, returning no window, and an empty one goes nowhere")
    func aWindowOpensHere() async throws {
        var opened: [URL?] = []
        let pageUI = BrowserPageUI { action, _ in opened.append(action.request.url) }
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let webView = Self.webView(pageUI, configuration: configuration)
        webView.loadHTMLString("<title>選課登記</title>", baseURL: Self.site)
        try await waitUntil { webView.title == "選課登記" }

        let next = "https://dialog-test.ntust.edu.tw/next"
        let windows = try await webView.evaluateJavaScript(
            "[window.open('\(next)'), window.open(), window.open('about:blank', 'blank')].map((opened) => opened === null)"
        )
        #expect(windows as? [Bool] == [true, true, true])
        #expect(opened == [URL(string: next)])
        withExtendedLifetime(pageUI) {}
    }

    private static func browsersWebView(_ page: BrowserPage, _ navigator: BrowserNavigator) throws -> WKWebView {
        let container = navigator.makeView(opening: site)
        // The start page would load from the network.
        page.signIn.load = { _ in }
        return try #require(container.subviews.compactMap { $0 as? WKWebView }.last)
    }

    @Test("the browser's own web view sends a window the page opens through the browser's rules")
    func theBrowsersWebViewOpensWindowsByItsRules() async throws {
        let page = BrowserPage()
        let navigator = BrowserNavigator(page: page, auth: nil)
        let webView = try Self.browsersWebView(page, navigator)
        webView.loadHTMLString("<title>選課登記</title>", baseURL: Self.site)
        try await waitUntil { webView.title == "選課登記" }

        let outside = try #require(URL(string: "https://example.invalid/form"))
        webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let opened = try await webView.evaluateJavaScript("window.open('\(outside.absoluteString)') === null")
        #expect(opened as? Bool == true)
        #expect(page.outside == outside)
        #expect(webView.url == Self.site)
        withExtendedLifetime(navigator) {}
    }

    private static func show(_ pageUI: BrowserPageUI, screen: Screen = Screen.all[0]) throws -> (UIWindow, WKWebView) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: screen.width, height: screen.height)
        window.overrideUserInterfaceStyle = screen.style
        if let textSize = screen.textSize { window.traitOverrides.preferredContentSizeCategory = textSize }
        let page = UIViewController()
        let webView = Self.webView(pageUI, configuration: WKWebViewConfiguration())
        webView.frame = window.bounds
        page.view.addSubview(webView)
        window.rootViewController = page
        window.makeKeyAndVisible()
        return (window, webView)
    }

    private static func shownAlert(over presenter: UIViewController?, after previous: UIAlertController? = nil) async throws -> UIAlertController {
        @MainActor func alert() -> UIAlertController? {
            guard let alert = presenter?.presentedViewController as? UIAlertController,
                  alert !== previous, !alert.isBeingPresented else { return nil }
            return alert
        }
        try await waitUntil { alert() != nil }
        return try #require(alert())
    }

    private static func tap(_ title: String, in alert: UIAlertController, window: UIWindow) async throws {
        try await waitUntil { accessibilityElement(labeled: title, in: alert.view) != nil }
        let button = try #require(accessibilityElement(labeled: title, in: alert.view))
        #expect(button.accessibilityTraits.contains(.button), "\(title)")
        try await PageMenuScreenTests.tap(button, in: window)
    }

    @Test("a confirm shows as the system's alert titled with the page's host, and OK reaches the page")
    func confirmOKReachesThePage() async throws {
        try await withAccessibilityAutomation {
            let pageUI = BrowserPageUI { _, _ in }
            let (window, webView) = try Self.show(pageUI)
            defer { window.isHidden = true }
            webView.loadHTMLString("<script>document.title = String(confirm('確定要送出這份登記嗎？'))</script>", baseURL: Self.site)

            let alert = try await Self.shownAlert(over: window.rootViewController)
            #expect(alert.title == Self.site.host())
            #expect(alert.message == "確定要送出這份登記嗎？")
            #expect(Set(alert.actions.compactMap(\.title)) == [Self.ok, Self.cancel])
            #expect(alert.textFields?.isEmpty ?? true)
            try await Self.tap(Self.ok, in: alert, window: window)

            try await waitUntil { webView.title == "true" }
            try await waitUntil { window.rootViewController?.presentedViewController == nil }
            #expect(pageUI.dialogs.shown == nil)
        }
    }

    @Test("Cancel answers a confirm false, and a prompt's field holds the page's text and answers with what was typed")
    func cancelAndPromptTextReachThePage() async throws {
        try await withAccessibilityAutomation {
            let pageUI = BrowserPageUI { _, _ in }
            let (window, webView) = try Self.show(pageUI)
            defer { window.isHidden = true }
            webView.loadHTMLString("""
            <script>
            const sure = confirm('要放棄這份表單嗎？');
            document.title = JSON.stringify([sure, prompt('第幾週？', '第一週')]);
            </script>
            """, baseURL: Self.site)

            let confirm = try await Self.shownAlert(over: window.rootViewController)
            try await Self.tap(Self.cancel, in: confirm, window: window)
            let prompt = try await Self.shownAlert(over: window.rootViewController, after: confirm)
            #expect(prompt.message == "第幾週？")
            let field = try #require(prompt.textFields?.first)
            #expect(field.text == "第一週")
            field.text = "第二週"
            try await Self.tap(Self.ok, in: prompt, window: window)

            try await waitUntil { webView.title == #"[false,"第二週"]"# }
            #expect(webView.title == #"[false,"第二週"]"#)
        }
    }

    @Test("a dialog asked while another is up shows once that one is answered, and each is answered once")
    func aSecondDialogWaitsItsTurn() async throws {
        try await withAccessibilityAutomation {
            let pageUI = BrowserPageUI { _, _ in }
            let (window, webView) = try Self.show(pageUI)
            defer { window.isHidden = true }
            webView.loadHTMLString("<script>alert('已儲存。'); document.title = 'answered'</script>", baseURL: Self.site)
            let first = try await Self.shownAlert(over: window.rootViewController)
            var answers: [String?] = []
            pageUI.dialogs.ask(.init(kind: .confirm, host: "embedded.example", message: "要繼續嗎？")) { answers.append($0) }

            #expect(first.message == "已儲存。")
            #expect(first.actions.compactMap(\.title) == [Self.ok])
            try await Self.tap(Self.ok, in: first, window: window)
            let second = try await Self.shownAlert(over: window.rootViewController, after: first)
            #expect(second.title == "embedded.example")
            #expect(second.message == "要繼續嗎？")
            try await Self.tap(Self.cancel, in: second, window: window)

            try await waitUntil { window.rootViewController?.presentedViewController == nil && webView.title == "answered" }
            #expect(answers == [nil])
        }
    }

    @Test("a dialog the page asks while a sheet is up over the browser shows over that sheet")
    func aDialogShowsOverASheet() async throws {
        try await withAccessibilityAutomation {
            let pageUI = BrowserPageUI { _, _ in }
            let (window, webView) = try Self.show(pageUI)
            defer { window.isHidden = true }
            let sheet = UIViewController()
            window.rootViewController?.present(sheet, animated: true)
            webView.loadHTMLString("<script>document.title = String(confirm('確定要送出嗎？'))</script>", baseURL: Self.site)

            let alert = try await Self.shownAlert(over: sheet)
            try await Self.tap(Self.ok, in: alert, window: window)
            try await waitUntil { webView.title == "true" }
            #expect(window.rootViewController?.presentedViewController === sheet)
        }
    }

    @Test("a dialog from a web view out of its window, with nowhere to show, is answered as cancelled")
    func aDialogWithNowhereToShowIsCancelled() async throws {
        let pageUI = BrowserPageUI { _, _ in }
        let webView = Self.webView(pageUI, configuration: WKWebViewConfiguration())
        webView.loadHTMLString("<script>document.title = String(confirm('確定要送出嗎？'))</script>", baseURL: Self.site)

        try await waitUntil { webView.title == "false" }
        #expect(pageUI.dialogs.shown == nil)
        withExtendedLifetime(pageUI) {}
    }

    enum Shot: String, CaseIterable {
        case alert, confirm, prompt

        var page: String {
            let ask = switch self {
            case .alert: "alert('登記已送出，請於第三週前確認結果。')"
            case .confirm: "confirm('確定要送出這份登記嗎？送出後就不能再修改。')"
            case .prompt: "prompt('請輸入要加註的週次', '第一週')"
            }
            return """
            <meta name="viewport" content="width=device-width">
            <h2>選課登記</h2><p>課程：資料結構（範例）</p><p><button>送出</button></p>
            <script>addEventListener('load', () => requestAnimationFrame(() => requestAnimationFrame(() => \(ask))))</script>
            """
        }
    }

    @Test("the alert over the page at 375 points, light and dark, with the largest text too",
          arguments: Shot.allCases, Screen.all.filter { $0.width == 375 })
    func picture(of shot: Shot, on screen: Screen) async throws {
        try await withAccessibilityAutomation {
            let pageUI = BrowserPageUI { _, _ in }
            let (window, webView) = try Self.show(pageUI, screen: screen)
            defer { window.isHidden = true }
            webView.loadHTMLString(shot.page, baseURL: Self.site)

            let alert = try await Self.shownAlert(over: window.rootViewController)
            #expect(alert.title == Self.site.host())
            if shot == .prompt { #expect(alert.textFields?.first?.text == "第一週") }
            try await Task.sleep(for: .milliseconds(600))
            window.saveSnapshot(as: "browser-dialog-\(shot)-\(screen.name)-\(PageMenuScreenTests.language)")
            try await Self.tap(Self.ok, in: alert, window: window)
            try await waitUntil { pageUI.dialogs.shown == nil }
        }
    }

    private final class Sites: NSObject, WKURLSchemeHandler {
        static let scheme = "tigerduck-test"
        let pages: [String: String]

        init(_ pages: [String: String]) {
            self.pages = pages
        }

        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            guard let url = task.request.url else { return }
            task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: -1, textEncodingName: "utf-8"))
            task.didReceive(Data((pages[url.host() ?? ""] ?? "").utf8))
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
    }

    @Test("a dialog from a frame of another site, sandboxed or not, is titled with that frame's host, and the page's with the page's")
    func eachFrameShowsItsOwnHost() async throws {
        let pageUI = BrowserPageUI { _, _ in }
        let dialogs = pageUI.dialogs
        dialogs.show = { _ in }
        let sites = Sites([
            "page.example": "<iframe src=\"\(Sites.scheme)://embedded.example/\"></iframe>",
            "embedded.example": "<script>alert('來自嵌入的網站')</script>",
            "sandboxed.example": "<script>alert('來自沙箱')</script>",
        ])
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(sites, forURLScheme: Sites.scheme)
        let webView = Self.webView(pageUI, configuration: configuration)
        webView.load(URLRequest(url: try #require(URL(string: "\(Sites.scheme)://page.example/"))))

        try await waitUntil { dialogs.shown != nil }
        let embedded = try #require(dialogs.shown)
        #expect(embedded.host == "embedded.example")
        #expect(embedded.message == "來自嵌入的網站")
        dialogs.answer(embedded, with: "")

        webView.evaluateJavaScript("alert('來自頁面')", completionHandler: nil)
        try await waitUntil { dialogs.shown != nil }
        let own = try #require(dialogs.shown)
        #expect(own.host == "page.example")
        dialogs.answer(own, with: "")

        let sandboxed = "<iframe sandbox=\"allow-scripts allow-modals\" src=\"\(Sites.scheme)://sandboxed.example/\"></iframe>"
        webView.evaluateJavaScript("document.body.insertAdjacentHTML('beforeend', '\(sandboxed)')", completionHandler: nil)
        try await waitUntil { dialogs.shown != nil }
        let opaque = try #require(dialogs.shown)
        #expect(opaque.host == "sandboxed.example")
        dialogs.answer(opaque, with: "")
        withExtendedLifetime((pageUI, sites)) {}
    }

    @Test("a dialog still up when the web view's delegate goes away is answered as cancelled")
    func goingAwayAnswersADialogStillUp() async throws {
        var pageUI: BrowserPageUI? = BrowserPageUI { _, _ in }
        let dialogs = try #require(pageUI?.dialogs)
        dialogs.show = { _ in }
        let webView = Self.webView(try #require(pageUI), configuration: WKWebViewConfiguration())
        webView.loadHTMLString("<script>document.title = String(confirm('要離開這個頁面嗎？'))</script>", baseURL: Self.site)
        try await waitUntil { dialogs.shown != nil }
        try #require(dialogs.shown != nil)

        withExtendedLifetime(pageUI) {}
        pageUI = nil
        try await waitUntil { webView.title == "false" }
        #expect(dialogs.shown == nil)
    }

    @Test("the browser's own web view brings its page's dialogs to its page UI")
    func theBrowsersWebViewBringsItsDialogsHere() async throws {
        let page = BrowserPage()
        let navigator = BrowserNavigator(page: page, auth: nil)
        let webView = try Self.browsersWebView(page, navigator)
        let dialogs = try #require((webView.uiDelegate as? BrowserPageUI)?.dialogs)
        dialogs.show = { _ in }
        webView.loadHTMLString("<script>document.title = String(confirm('確定要送出嗎？'))</script>", baseURL: Self.site)

        try await waitUntil { dialogs.shown != nil }
        let shown = try #require(dialogs.shown)
        #expect(shown.host == Self.site.host())
        dialogs.answer(shown, with: "")
        try await waitUntil { webView.title == "true" }
        #expect(webView.title == "true")
        withExtendedLifetime(navigator) {}
    }
}
#endif
