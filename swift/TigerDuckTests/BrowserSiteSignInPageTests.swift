#if os(iOS)
import Testing
import UIKit
import WebKit
@testable import TigerDuck

/// The sign-in form script in a real web view, on hand-written pages at the sites' addresses;
/// listed in `on_screen_tests` in `.github/workflows/tests.yaml`.
@MainActor
struct BrowserSiteSignInPageTests {
    private static let ethics = URL(string: "https://stuinfosys.ntust.edu.tw/Authenticate/Account/EnrollStudent/ethicscourse")!
    /// The research ethics sign-in as the school serves it: student id, password and an image CAPTCHA.
    private static let ethicsForm = """
    <form method="post" action="/Authenticate/Account/EnrollStudent/ethicscourse">
    <input name="__RequestVerificationToken" type="hidden" value="t">
    <input name="UserName" type="text"><input name="Password" type="password">
    <img id="valiCode" alt=""><input name="VerifyCode" type="text">
    <input type="submit" value="sign in"><input name="SystemName" type="hidden" value="ethicscourse">
    </form>
    """

    private final class Loader: NSObject, WKNavigationDelegate {
        var loaded: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded?.resume()
            loaded = nil
        }
    }

    private func page(_ body: String, at url: URL, script: String = "") async -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: configuration)
        let loader = Loader()
        webView.navigationDelegate = loader
        await withCheckedContinuation { loader.loaded = $0; webView.loadHTMLString("<body>\(body)<script>\(script)</script></body>", baseURL: url) }
        withExtendedLifetime(loader) {}
        return webView
    }

    private func values(_ webView: WKWebView, _ names: [String]) async -> [String] {
        let script = "return names.map((name) => document.getElementsByName(name)[0].value)"
        return (try? await webView.callAsyncJavaScript(script, arguments: ["names": names], contentWorld: .page)) as? [String] ?? []
    }

    private static let account = BrowserSiteSignIn.Account(studentId: "B00000001", password: "not-a-password")
    private let signIn = BrowserSiteSignIn { Self.account }

    @Test func fillsTheStudentIdAndPasswordAndLeavesTheCAPTCHA() async {
        let webView = await page(Self.ethicsForm, at: Self.ethics, script: """
        window.typed = [];
        document.querySelectorAll('input').forEach((input) => input.addEventListener('input', () => typed.push(input.name)));
        """)
        await signIn.pageFinished(in: webView)

        #expect(await values(webView, ["UserName", "Password", "VerifyCode"]) == ["B00000001", "not-a-password", ""])
        let typed = try? await webView.callAsyncJavaScript("return typed", contentWorld: .page) as? [String]
        #expect(typed == ["UserName", "Password"])
    }

    @Test func fillsTheStudentCardSignInAndLeavesItsCAPTCHA() async {
        let form = """
        <form id="form1" method="post" action="https://cardsystem.ntust.edu.tw/std/index.php/user/agreement">
        <input name="id" type="text"><input name="password" type="password"><input name="verify" type="text">
        <input id="button" type="submit" value="sign in"><input name="utoken" type="hidden" value="t">
        </form>
        """
        let webView = await page(form, at: URL(string: "https://cardsystem.ntust.edu.tw/std/index.php/user/login")!)
        await signIn.pageFinished(in: webView)
        #expect(await values(webView, ["id", "password", "verify", "utoken"]) == ["B00000001", "not-a-password", "", "t"])
    }

    @Test func leavesWhatTheStudentTyped() async {
        let webView = await page(Self.ethicsForm, at: Self.ethics, script: "document.getElementsByName('UserName')[0].value = 'M11000000'")
        await signIn.pageFinished(in: webView)
        #expect(await values(webView, ["UserName", "Password"]) == ["M11000000", "not-a-password"])
    }

    @Test func aPageElsewhereOrAPasswordFieldThatIsNotOneGetsNothing() async {
        let elsewhere = URL(string: "https://stuinfosys.ntust.edu.tw/Authenticate/Account/EnrollStudent/other")!
        let other = await page(Self.ethicsForm, at: elsewhere)
        await signIn.pageFinished(in: other)
        #expect(await values(other, ["UserName", "Password"]) == ["", ""])

        let shown = Self.ethicsForm.replacingOccurrences(of: "name=\"Password\" type=\"password\"", with: "name=\"Password\" type=\"text\"")
        let plain = await page(shown, at: Self.ethics)
        await signIn.pageFinished(in: plain)
        #expect(await values(plain, ["UserName", "Password"]) == ["", ""])
    }

    @Test func theScriptChecksTheAddressAsItFills() async {
        let webView = await page(Self.ethicsForm, at: Self.ethics)
        let arguments = [
            "origin": "https://stuinfosys.ntust.edu.tw", "path": "/Authenticate/SSOAccount/Index/SSOcgesocial",
            "studentIdField": "UserName", "passwordField": "Password", "studentId": "B00000001", "password": "not-a-password",
        ]
        let filled = try? await webView.callAsyncJavaScript(BrowserSiteSignIn.fill, arguments: arguments, contentWorld: .defaultClient)
        #expect(filled as? Bool == false)
        #expect(await values(webView, ["UserName", "Password"]) == ["", ""])
    }
}
#endif
