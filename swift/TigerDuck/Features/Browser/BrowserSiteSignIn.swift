import WebKit

/// Signs the browser in to a school site with a password of its own, or fills its sign-in form,
/// on each page the browser finishes loading. The values go to the page as arguments, and only
/// into the main frame at an address `BrowserSchoolSites` lists, which the script checks again as
/// it uses them.
@MainActor
struct BrowserSiteSignIn {
    struct Account {
        let studentId: String
        let password: String
    }

    var account: () -> Account?
    /// Whether the app's school session is live, renewed where it lapsed, so the stored password
    /// is one the school takes.
    var sessionIsLive: () async -> Bool = { false }
    /// Runs a post of the stored password the site makes itself, which answers its HTTP status,
    /// under the app's rules for automatic posts; nil when the rules hold it back.
    var postingStoredPassword: @MainActor (_ post: @MainActor () async -> Int?) async -> Int? = { await $0() }

    func pageFinished(in webView: WKWebView) async {
        guard let url = webView.url, let page = BrowserSchoolSites.page(of: url) else { return }
        if page.origin + page.path == BrowserSchoolSites.tokenSignInPage {
            return await signInWithToken(in: webView, at: ["origin": page.origin, "path": page.path])
        }
        guard let form = BrowserSchoolSites.signInForm(at: url), let account = account() else { return }
        var arguments: [String: Any] = [
            "origin": page.origin, "path": page.path, "studentIdField": form.studentId, "studentId": account.studentId,
            "passwordField": NSNull(), "password": NSNull(),
        ]
        if let passwordField = form.password {
            arguments["passwordField"] = passwordField
            arguments["password"] = account.password
        }
        await run(Self.fill, arguments, in: webView, world: .defaultClient)
    }

    /// The credit program system: a token it still takes is kept; else the stored password is
    /// posted as its popup posts it, and the popup opens for the student when that does not sign in.
    private func signInWithToken(in webView: WKWebView, at page: [String: Any]) async {
        guard await run(Self.savedToken, page, in: webView, world: .defaultClient) as? String == "signedOut" else { return }
        if await sessionIsLive(), let account = account() {
            let arguments = page.merging(["studentId": account.studentId, "password": account.password]) { $1 }
            let status = await postingStoredPassword { await run(Self.postToken, arguments, in: webView, world: .defaultClient) as? Int }
            if let status, (200..<300).contains(status) { return }
        }
        await run(Self.openPopup, page, in: webView, world: .page)
    }

    @discardableResult
    private func run(_ script: String, _ arguments: [String: Any], in webView: WKWebView, world: WKContentWorld) async -> Any? {
        do {
            return try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: world)
        } catch {
            AppLogger.breadcrumb("a school site's sign-in script did not finish", category: "browser")
            return nil
        }
    }

    /// Fills only empty fields, as the student may have typed, and leaves every other field alone:
    /// nothing unless the fields share one form that posts to the page's own origin, and the
    /// password only beside the stored student id, never beside one the student typed.
    nonisolated static let fill = """
    if (location.origin !== origin || location.pathname !== path) return false;
    const field = (name) => Array.prototype.find.call(
      document.getElementsByName(name), (element) => element instanceof HTMLInputElement && element.form !== null);
    const id = field(studentIdField), secret = passwordField === null ? null : field(passwordField);
    if (!id || (passwordField !== null && (!secret || secret.type !== 'password' || secret.form !== id.form))) return false;
    if (new URL(id.form.action).origin !== origin) return false;
    const fills = secret && (!id.value || id.value === studentId) ? [[id, studentId], [secret, password]] : [[id, studentId]];
    for (const [element, value] of fills) {
      if (element.value) continue;
      element.value = value;
      element.dispatchEvent(new Event('input', { bubbles: true }));
      element.dispatchEvent(new Event('change', { bubbles: true }));
    }
    return true;
    """

    /// The credit program system keeps the token its sign-in popup gets from `api/tokens` in a
    /// `token` cookie, which its pages send to `api/` as a bearer token.
    nonisolated static let savedToken = """
    if (location.origin !== origin || location.pathname !== path) return 'elsewhere';
    const saved = document.cookie.split('; ').find((cookie) => cookie.startsWith('token='));
    if (saved) {
      try {
        const users = await fetch('api/users', { headers: { Authorization: 'Bearer ' + decodeURIComponent(saved.slice(6)) } });
        if (users.ok) return 'signedIn';
      } catch (error) {}
    }
    return 'signedOut';
    """

    /// Posts the account as the popup does and keeps the token as the site does. Answers the HTTP
    /// status, or null when no answer or no token came; a redirect fails rather than send the
    /// password on.
    nonisolated static let postToken = """
    if (location.origin !== origin || location.pathname !== path) return null;
    let answer;
    try {
      answer = await fetch('api/tokens', {
        method: 'post', redirect: 'error', body: JSON.stringify({ AccountId: studentId, Password: password }),
        headers: { 'Content-Type': 'application/json; charset=utf-8' },
      });
    } catch (error) {
      return null;
    }
    if (!answer.ok) return answer.status;
    const token = await answer.json().then((body) => body.Token, () => null);
    if (typeof token !== 'string' || !token || location.origin !== origin || location.pathname !== path) return null;
    document.cookie = 'token=' + encodeURIComponent(token) + '; path=/; max-age=86400';
    location.reload();
    return answer.status;
    """

    /// Run in the page's world, which holds the Vue app whose store opens the popup.
    nonisolated static let openPopup = """
    if (location.origin !== origin || location.pathname !== path) return false;
    const app = document.getElementById('app');
    const store = app && app.__vue__ && app.__vue__.$store;
    if (store) store.commit('setShowLogin', true);
    return !!store;
    """
}

extension BrowserSiteSignIn {
    init(auth: AuthService?, for signIn: SignIn) {
        self.init { [weak auth] in
            guard !signIn.isDemo, signIn.isCurrent, let studentId = auth?.storedStudentId, let password = auth?.storedPassword else {
                return nil
            }
            return Account(studentId: studentId, password: password)
        } sessionIsLive: { [weak auth] in
            guard !signIn.isDemo, signIn.isCurrent, let auth else { return false }
            return await auth.ensureAuthenticated(for: signIn)
        } postingStoredPassword: { post in
            await SchoolAccountSignIn.postStoredPassword(for: signIn, post)
        }
    }

    /// What the browser loads to open `start`: its site's sign-in link where it has one, with the
    /// host's cookies gone once they pass `BrowserSchoolSites.cookieBudget`.
    static func opening(_ start: URL, for signIn: SignIn, in store: WKWebsiteDataStore) async -> URL {
        let opening = signIn.isDemo ? start : BrowserSchoolSites.signInLink(for: start) ?? start
        for cookie in BrowserSchoolSites.cookiesToDrop(from: await store.httpCookieStore.allCookies(), opening: opening) {
            await store.httpCookieStore.deleteCookie(cookie)
        }
        return opening
    }
}
