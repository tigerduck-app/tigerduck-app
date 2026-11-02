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

    /// Lets the first page load and refuses, and counts, any navigation after it.
    private final class Loader: NSObject, WKNavigationDelegate {
        var loaded: CheckedContinuation<Void, Never>?
        var refused: [WKNavigationType] = []
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded?.resume()
            loaded = nil
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard loaded == nil else { return decisionHandler(.allow) }
            refused.append(action.navigationType)
            decisionHandler(.cancel)
        }
    }

    private func page(_ body: String, at url: URL, script: String = "") async -> WKWebView {
        await page(body, at: url, script: script, loader: Loader())
    }

    private func page(_ body: String, at url: URL, script: String = "", loader: Loader) async -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: configuration)
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
    private let signIn = BrowserSiteSignIn(account: { Self.account })

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

    @Test func fillsTheWorkStudySignInAndLeavesItsCAPTCHA() async {
        let form = """
        <form id="Form1" method="post" action="./"><input name="__VIEWSTATE" type="hidden" value="v">
        <input name="studentno" type="text"><input name="password" type="password"><input name="code_box" type="text">
        <input name="Button1" type="submit" value="sign in"></form>
        """
        let webView = await page(form, at: URL(string: "https://studentpay.ntust.edu.tw/")!)
        await signIn.pageFinished(in: webView)
        #expect(await values(webView, ["studentno", "password", "code_box"]) == ["B00000001", "not-a-password", ""])
    }

    /// Its sign-in form sits between two forms that ask for a student id alone, and its reCAPTCHA
    /// is a widget the student taps. Its password is the career site's, not the school's.
    @Test func fillsOnlyTheSuggestionBoxStudentIdAndLeavesItsReCAPTCHA() async throws {
        let forms = """
        <form method="post" action="/send-forget-email"><input name="_token" type="hidden" value="t">
        <input name="student_id" type="text"><button type="submit">send</button></form>
        <form class="form_login" method="post" action="/login"><input name="_token" type="hidden" value="t">
        <input name="account"><input name="password" type="password">
        <div id="grecaptcha"><textarea name="g-recaptcha-response"></textarea></div><button type="submit">sign in</button></form>
        <form method="post" action="/send-email"><input name="student_id" type="text"><button type="submit">send</button></form>
        """
        let webView = await page(forms, at: URL(string: "https://suggestionbox.ntust.edu.tw/login")!)
        await signIn.pageFinished(in: webView)
        #expect(await values(webView, ["account", "password", "g-recaptcha-response", "student_id"]) == ["B00000001", "", "", ""])
        let others = "return [...document.getElementsByName('student_id')].map((field) => field.value)"
        #expect(try await webView.callAsyncJavaScript(others, contentWorld: .page) as? [String] == ["", ""])
    }

    @Test func leavesWhatTheStudentTypedAndGivesThePasswordOnlyToTheStoredId() async {
        let other = await page(Self.ethicsForm, at: Self.ethics, script: "document.getElementsByName('UserName')[0].value = 'M11000000'")
        await signIn.pageFinished(in: other)
        #expect(await values(other, ["UserName", "Password"]) == ["M11000000", ""])

        let same = await page(Self.ethicsForm, at: Self.ethics, script: "document.getElementsByName('UserName')[0].value = 'B00000001'")
        await signIn.pageFinished(in: same)
        #expect(await values(same, ["UserName", "Password"]) == ["B00000001", "not-a-password"])
    }

    @Test func fieldsInTwoFormsOrInAFormThatPostsElsewhereGetNothing() async {
        let split = "<form action=\"/a\"><input name=\"UserName\" type=\"text\"></form>"
            + "<form action=\"/b\"><input name=\"Password\" type=\"password\"></form>"
        let apart = await page(split, at: Self.ethics)
        await signIn.pageFinished(in: apart)
        #expect(await values(apart, ["UserName", "Password"]) == ["", ""])

        let away = Self.ethicsForm.replacingOccurrences(
            of: "action=\"/Authenticate/Account/EnrollStudent/ethicscourse\"", with: "action=\"https://elsewhere.test/collect\"")
        let elsewhere = await page(away, at: Self.ethics)
        await signIn.pageFinished(in: elsewhere)
        #expect(await values(elsewhere, ["UserName", "Password"]) == ["", ""])
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

    /// The credit program system as its landing page runs: a Vue app on `#app` whose store opens
    /// the sign-in popup. Its own `fetch` answers nothing, so a request made from the page's world
    /// shows in `trapped`.
    private static let creditPrograms = URL(string: "https://cour01.ntust.edu.tw/DMP_student/")!
    private static let creditProgramApp = """
    window.trapped = []; window.commits = [];
    window.fetch = async (address) => { trapped.push(String(address)); return new Response('{}', { status: 500 }); };
    document.getElementById('app').__vue__ = { $store: { commit: (name, value) => commits.push([name, value]) } };
    """
    /// The site's `api/` as the browser's own script world reaches it, answered with `answers`.
    private static let creditProgramServer = """
    window.requests = [];
    window.answers = { 'api/tokens': [200, { Token: 'a.b-c' }], 'api/users': [401, {}] };
    window.fetch = async (address, init = {}) => {
      requests.push([String(address), init.method || 'get', init.body || null, (init.headers || {})['Content-Type'] || null, init.redirect || null]);
      const [status, body] = answers[address];
      return new Response(JSON.stringify(body), { status });
    };
    """

    private func creditProgramPage(answers: String = "", cookie: String = "", loader: Loader = Loader()) async -> WKWebView {
        let webView = await page("<div id=\"app\"></div>", at: Self.creditPrograms, script: Self.creditProgramApp + cookie, loader: loader)
        _ = try? await webView.callAsyncJavaScript(Self.creditProgramServer + answers, contentWorld: .defaultClient)
        return webView
    }

    private func read(_ webView: WKWebView, _ expression: String, in world: WKContentWorld = .page) async -> String? {
        (try? await webView.callAsyncJavaScript("return JSON.stringify(" + expression + ")", contentWorld: world)) as? String
    }

    /// The statuses of the posts the stored-password rules let through.
    private final class Posts {
        var statuses: [Int?] = []
    }

    private func creditProgramSignIn(_ posts: Posts, sessionIsLive: Bool = true) -> BrowserSiteSignIn {
        BrowserSiteSignIn(account: { Self.account }, sessionIsLive: { sessionIsLive }, postingStoredPassword: { post in
            let status = await post()
            posts.statuses.append(status)
            return status
        })
    }

    @Test func signsInToTheCreditProgramsAsItsPopupDoes() async {
        let loader = Loader(), posts = Posts()
        let webView = await creditProgramPage(loader: loader)
        await creditProgramSignIn(posts).pageFinished(in: webView)

        let post = #"[["api/tokens","post","{\"AccountId\":\"B00000001\",\"Password\":\"not-a-password\"}","application/json; charset=utf-8","error"]]"#
        #expect(await read(webView, "requests", in: .defaultClient) == post)
        #expect(posts.statuses == [200])
        #expect(await read(webView, "trapped") == "[]", "nothing goes through the page's own fetch")
        #expect(await read(webView, "document.cookie") == #""token=a.b-c""#)
        #expect(await read(webView, "commits") == "[]")
        #expect(loader.refused == [.reload])
    }

    @Test func aRefusedSignInOpensThePopupForTheStudent() async {
        let loader = Loader(), posts = Posts()
        let webView = await creditProgramPage(answers: "answers['api/tokens'] = [400, {}];", loader: loader)
        await creditProgramSignIn(posts).pageFinished(in: webView)

        #expect(await read(webView, "requests.map((request) => request[0])", in: .defaultClient) == #"["api/tokens"]"#)
        #expect(posts.statuses == [400])
        #expect(await read(webView, "document.cookie") == #""""#)
        #expect(await read(webView, "commits") == #"[["setShowLogin",true]]"#)
        #expect(loader.refused.isEmpty)
    }

    @Test func aPostTheStoredPasswordRulesHoldBackOpensThePopup() async {
        let webView = await creditProgramPage()
        let heldBack = BrowserSiteSignIn(account: { Self.account }, sessionIsLive: { true }, postingStoredPassword: { _ in nil })
        await heldBack.pageFinished(in: webView)

        #expect(await read(webView, "requests", in: .defaultClient) == "[]")
        #expect(await read(webView, "commits") == #"[["setShowLogin",true]]"#)
    }

    @Test func withNoLiveSchoolSessionThePopupOpensAndNothingIsPosted() async {
        let posts = Posts()
        let webView = await creditProgramPage()
        await creditProgramSignIn(posts, sessionIsLive: false).pageFinished(in: webView)

        #expect(await read(webView, "requests", in: .defaultClient) == "[]")
        #expect(posts.statuses.isEmpty)
        #expect(await read(webView, "commits") == #"[["setShowLogin",true]]"#)
    }

    @Test func aTokenThePageStillTakesIsKept() async {
        let webView = await creditProgramPage(answers: "answers['api/users'] = [200, {}];", cookie: "document.cookie = 'token=old';")
        await creditProgramSignIn(Posts()).pageFinished(in: webView)

        #expect(await read(webView, "requests.map((request) => request[0])", in: .defaultClient) == #"["api/users"]"#)
        #expect(await read(webView, "document.cookie") == #""token=old""#)
        #expect(await read(webView, "commits") == "[]")
    }
}
#endif
