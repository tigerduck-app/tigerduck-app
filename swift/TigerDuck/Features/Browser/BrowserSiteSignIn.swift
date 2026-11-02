import WebKit

/// Fills a school site's own sign-in form on each page the browser finishes loading. The values
/// go to the page as arguments, and only into the main frame at an address
/// `BrowserSchoolSites.signInForm(at:)` lists, which the script checks again as it fills.
@MainActor
struct BrowserSiteSignIn {
    struct Account {
        let studentId: String
        let password: String
    }

    var account: () -> Account?

    func pageFinished(in webView: WKWebView) async {
        guard let url = webView.url, let form = BrowserSchoolSites.signInForm(at: url),
              let page = BrowserSchoolSites.page(of: url), let account = account() else { return }
        let arguments = [
            "origin": page.origin, "path": page.path, "studentIdField": form.studentId, "passwordField": form.password,
            "studentId": account.studentId, "password": account.password,
        ]
        do {
            _ = try await webView.callAsyncJavaScript(Self.fill, arguments: arguments, in: nil, contentWorld: .defaultClient)
        } catch {
            AppLogger.breadcrumb("a school site's sign-in form was not filled", category: "browser")
        }
    }

    /// Fills only empty fields, as the student may have typed, and leaves every other field alone.
    nonisolated static let fill = """
    if (location.origin !== origin || location.pathname !== path) return false;
    const field = (name) => Array.prototype.find.call(
      document.getElementsByName(name), (element) => element instanceof HTMLInputElement && element.form !== null);
    const id = field(studentIdField), secret = field(passwordField);
    if (!id || !secret || secret.type !== 'password') return false;
    for (const [element, value] of [[id, studentId], [secret, password]]) {
      if (element.value) continue;
      element.value = value;
      element.dispatchEvent(new Event('input', { bubbles: true }));
      element.dispatchEvent(new Event('change', { bubbles: true }));
    }
    return true;
    """
}

extension BrowserSiteSignIn {
    init(auth: AuthService?, for signIn: SignIn) {
        self.init { [weak auth] in
            guard !signIn.isDemo, signIn.isCurrent, let studentId = auth?.storedStudentId, let password = auth?.storedPassword else {
                return nil
            }
            return Account(studentId: studentId, password: password)
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
