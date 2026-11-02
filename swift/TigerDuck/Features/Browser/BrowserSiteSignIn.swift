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

    func pageFinished(in webView: WKWebView) async {
        guard let url = webView.url, let page = BrowserSchoolSites.page(of: url) else { return }
        if page.origin + page.path == BrowserSchoolSites.tokenSignInPage {
            let account = await sessionIsLive() ? account() : nil
            let arguments: [String: Any] = [
                "origin": page.origin, "path": page.path,
                "studentId": account?.studentId ?? NSNull(), "password": account?.password ?? NSNull(),
            ]
            return await run(Self.tokenSignIn, arguments, in: webView, world: .page)
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

    private func run(_ script: String, _ arguments: [String: Any], in webView: WKWebView, world: WKContentWorld) async {
        do {
            _ = try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: world)
        } catch {
            AppLogger.breadcrumb("a school site's sign-in script did not finish", category: "browser")
        }
    }

    /// Fills only empty fields, as the student may have typed, and leaves every other field alone.
    /// The password goes only beside the stored student id, never beside one the student typed.
    nonisolated static let fill = """
    if (location.origin !== origin || location.pathname !== path) return false;
    const field = (name) => Array.prototype.find.call(
      document.getElementsByName(name), (element) => element instanceof HTMLInputElement && element.form !== null);
    const id = field(studentIdField), secret = passwordField === null ? null : field(passwordField);
    if (!id || (passwordField !== null && (!secret || secret.type !== 'password'))) return false;
    const fills = secret && (!id.value || id.value === studentId) ? [[id, studentId], [secret, password]] : [[id, studentId]];
    for (const [element, value] of fills) {
      if (element.value) continue;
      element.value = value;
      element.dispatchEvent(new Event('input', { bubbles: true }));
      element.dispatchEvent(new Event('change', { bubbles: true }));
    }
    return true;
    """

    /// The credit program system's sign-in popup posts the account to `api/tokens` and keeps the
    /// token it answers in a `token` cookie, which its pages send as a bearer token. Run in the
    /// page's world, which holds the Vue app whose store opens the popup.
    nonisolated static let tokenSignIn = """
    const here = () => location.origin === origin && location.pathname === path;
    if (!here()) return 'elsewhere';
    const call = async (address, init) => { try { return await fetch(address, init); } catch (error) { return null; } };
    const saved = document.cookie.split('; ').find((cookie) => cookie.startsWith('token='));
    if (saved) {
      const users = await call('api/users', { headers: { Authorization: 'Bearer ' + decodeURIComponent(saved.slice(6)) } });
      if (users && users.ok) return 'signedIn';
    }
    let token = null;
    if (studentId !== null && here()) {
      const answer = await call('api/tokens', {
        method: 'post', body: JSON.stringify({ AccountId: studentId, Password: password }),
        headers: { 'Content-Type': 'application/json; charset=utf-8' },
      });
      if (answer && answer.ok) token = await answer.json().then((body) => body.Token, () => null);
    }
    if (typeof token === 'string' && token && here()) {
      document.cookie = 'token=' + encodeURIComponent(token) + '; path=/; max-age=86400';
      location.reload();
      return 'signedIn';
    }
    const app = document.getElementById('app');
    const store = app && app.__vue__ && app.__vue__.$store;
    if (store) store.commit('setShowLogin', true);
    return 'popup';
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
