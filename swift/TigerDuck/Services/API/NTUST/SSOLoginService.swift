import Defaults
import Foundation
import os

enum SSOLoginError: LocalizedError {
    case loginFormNotFound
    /// The service sent the sign-in to ssoam's NetIQ form, which only a browser can submit.
    case interactiveLoginRequired
    case loginFailed(reason: String?)
    case networkError(Error)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .loginFormNotFound, .interactiveLoginRequired:
            return String(localized: "error_sso_sign_in_form_not_found")
        case .loginFailed(let reason?) where !reason.isEmpty:
            return String(format: String(localized: "error_sso_sign_in_failed_with_reason"), reason)
        case .loginFailed: return String(localized: "error_sso_sign_in_failed")
        case .networkError(let e): return String(format: String(localized: "error_network_format"), e.localizedDescription)
        case .invalidResponse: return String(localized: "error_invalid_server_response")
        }
    }
}

enum SSOLoginService {

    /// Decode an HTML response respecting `Content-Type` charset. Older NTUST
    /// endpoints occasionally serve Big5 (or windows-1252 for ASCII-only
    /// pages); a hard UTF-8 decode would return nil on those and surface as
    /// `invalidResponse` for what is otherwise a recoverable response.
    private static func decodeHTML(_ data: Data, response: URLResponse?) -> String? {
        let charset = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?
            .lowercased()
        if let charset {
            if charset.contains("big5") {
                if let s = String(data: data, encoding: .init(rawValue:
                    CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))
                )) { return s }
            }
            if charset.contains("windows-1252") || charset.contains("iso-8859-1") {
                if let s = String(data: data, encoding: .isoLatin1) { return s }
            }
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        // Last-ditch: try Big5 even if not declared.
        let big5 = String.Encoding(rawValue:
            CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        return String(data: data, encoding: big5)
    }

    /// How many times in a row the school refused the stored password in sign-ins the user did not
    /// start, and when it last did. Each refusal counts toward the account's lockout, so the next
    /// such sign-in waits ``storedPasswordRetryDelay(afterRefusals:)`` before it posts the password
    /// again. A sign-in the user typed never waits and clears the count, as a post the school
    /// accepts and a sign-out do.
    nonisolated static var storedPasswordRefusals: (count: Int, last: Date?) {
        get { (Defaults[.ntustStoredPasswordRefusals], Defaults[.ntustStoredPasswordRefusedAt]) }
        set {
            Defaults[.ntustStoredPasswordRefusals] = newValue.count
            Defaults[.ntustStoredPasswordRefusedAt] = newValue.last
        }
    }

    /// Posted on `NotificationCenter.default` when automatic posts of the stored password have to
    /// wait: at each refusal ``storedPasswordRefusals`` counts and at each post one holds back, so
    /// `AuthService` arms a try for when the wait is over, after a relaunch too. Its `userInfo`
    /// holds that time under ``storedPasswordRetryAtKey``.
    nonisolated static let storedPasswordPostWaits = Notification.Name("TigerDuck.storedPasswordPostWaits")
    nonisolated static let storedPasswordRetryAtKey = "retryAt"

    /// The waits after the first refusals in a row. Every later wait is
    /// ``storedPasswordRetryInterval``, so a password changed elsewhere then goes out four times a day.
    nonisolated static let storedPasswordQuickRetries: [TimeInterval] = [10, 60, 5 * 60]
    nonisolated static let storedPasswordRetryInterval: TimeInterval = 6 * 60 * 60

    nonisolated static func storedPasswordRetryDelay(afterRefusals refusals: Int) -> TimeInterval {
        refusals > storedPasswordQuickRetries.count
            ? storedPasswordRetryInterval
            : storedPasswordQuickRetries[max(refusals, 1) - 1]
    }

    /// When an automatic post of the stored password may go next, or nil when no refusal holds one
    /// back. Measured from the last refusal, so a clock set back does not stretch the wait.
    nonisolated static func storedPasswordRetryAt(refusals: Int, lastRefusal: Date?, now: Date) -> Date? {
        guard refusals > 0 else { return nil }
        guard let lastRefusal, lastRefusal <= now else { return now }
        return lastRefusal.addingTimeInterval(storedPasswordRetryDelay(afterRefusals: refusals))
    }

    nonisolated static func storedPasswordRetryAt(now: Date = Date()) -> Date? {
        let refusals = storedPasswordRefusals
        return storedPasswordRetryAt(refusals: refusals.count, lastRefusal: refusals.last, now: now)
    }

    /// Whether an automatic post of the stored password has to wait at `now`, which
    /// ``storedPasswordPostWaits`` announces.
    nonisolated static func storedPasswordPostMustWait(now: Date = Date()) -> Bool {
        guard let retryAt = storedPasswordRetryAt(now: now), retryAt > now else { return false }
        announceStoredPasswordWait(until: retryAt)
        return true
    }

    nonisolated static func noteStoredPasswordRefused(at now: Date = Date()) {
        let count = storedPasswordRefusals.count + 1
        storedPasswordRefusals = (count, now)
        announceStoredPasswordWait(until: now.addingTimeInterval(storedPasswordRetryDelay(afterRefusals: count)))
    }

    /// From the main actor: off it, the post would hold this thread until the main queue ran the
    /// observer.
    private nonisolated static func announceStoredPasswordWait(until retryAt: Date) {
        Task { @MainActor in
            NotificationCenter.default.post(
                name: storedPasswordPostWaits, object: nil, userInfo: [storedPasswordRetryAtKey: retryAt]
            )
        }
    }

    nonisolated static func forgetStoredPasswordRefusals() {
        storedPasswordRefusals = (0, nil)
    }

    private nonisolated static let storedPasswordPosts = AsyncSerialLock()

    /// How many automatic posts of the stored password wait for the one under way.
    nonisolated static func storedPasswordPostsWaiting() async -> Int {
        await storedPasswordPosts.waiterCount
    }

    /// Runs `body` alone among the automatic posts of the stored password: the SSO sign-ins here
    /// and `MoodleTokenService`'s token renewal. Two at once would each post a password the school
    /// refused before either counted the refusal, and the school counts both toward the lockout.
    /// `body` checks ``storedPasswordPostMustWait(now:)``, posts, reads the answer and counts a
    /// refusal before it returns. A sign-in the user typed posts what was typed, so it does not wait.
    nonisolated(nonsending) static func postingStoredPassword<T>(
        _ body: nonisolated(nonsending) () async throws -> T
    ) async rethrows -> T {
        await storedPasswordPosts.acquire()
        do {
            let result = try await body()
            await storedPasswordPosts.release()
            return result
        } catch {
            await storedPasswordPosts.release()
            throw error
        }
    }

    private static var isLoginRunning = false
    private static var waitingLogins: [CheckedContinuation<Void, Never>] = []

    /// Runs `body` once every login started before it has finished. A login that meets the
    /// SSO page clears the ssoam2 cookies, so two at once break each other. An automatic login
    /// that waited then finds the session signed in and posts no password; one the user typed
    /// still posts what was typed.
    static func oneAtATime<T>(_ body: () async throws -> T) async rethrows -> T {
        if isLoginRunning {
            await withCheckedContinuation { waitingLogins.append($0) }
        } else {
            isLoginRunning = true
        }
        defer {
            if waitingLogins.isEmpty {
                isLoginRunning = false
            } else {
                waitingLogins.removeFirst().resume()
            }
        }
        return try await body()
    }

    /// Ensures the user is signed in to `serviceURL` through NTUST SSO, as the Python
    /// `NtustSsoBridge.ensure_service_login` flow does. `generation` is
    /// ``NTUSTSessionManager/generation`` when the credentials were read; once a sign-out moves
    /// it, the login throws `CancellationError` before its next request. `interactive` marks a
    /// sign-in the user started; any other posts no password while the school's refusals hold it
    /// back (``storedPasswordRefusals``), and runs under ``postingStoredPassword(_:)``. `now`
    /// times the refusals, and `logFailure` gets each failure but a cancellation.
    static func ensureServiceLogin(
        session: URLSession,
        serviceURL: URL,
        studentId: String,
        password: String,
        generation: Int,
        interactive: Bool = false,
        now: () -> Date = { Date() },
        logFailure: @escaping @MainActor (any Error) -> Void = {
            AppLogger.captureError($0, context: ["service": "ssoEnsureServiceLogin"])
        }
    ) async throws -> Bool {
        guard !interactive else {
            return try await signIn(
                session: session, serviceURL: serviceURL, studentId: studentId, password: password,
                generation: generation, interactive: true, now: now, logFailure: logFailure
            )
        }
        return try await postingStoredPassword {
            try await signIn(
                session: session, serviceURL: serviceURL, studentId: studentId, password: password,
                generation: generation, interactive: false, now: now, logFailure: logFailure
            )
        }
    }

    private static func signIn(
        session: URLSession,
        serviceURL: URL,
        studentId: String,
        password: String,
        generation: Int,
        interactive: Bool,
        now: () -> Date,
        logFailure: @escaping @MainActor (any Error) -> Void
    ) async throws -> Bool {
        try await oneAtATime {
            try checkSignedIn(generation)
            let signedIn = try await performServiceLogin(
                session: session, serviceURL: serviceURL, studentId: studentId, password: password,
                generation: generation, interactive: interactive, now: now, logFailure: logFailure
            )
            if interactive, signedIn { forgetStoredPasswordRefusals() }
            return signedIn
        }
    }

    private static func checkSignedIn(_ generation: Int) throws {
        if NTUSTSessionManager.shared.generation != generation { throw CancellationError() }
    }

    private static func performServiceLogin(
        session: URLSession,
        serviceURL: URL,
        studentId: String,
        password: String,
        generation: Int,
        interactive: Bool,
        now: () -> Date,
        logFailure: @MainActor (any Error) -> Void
    ) async throws -> Bool {
        do {
            // Steps 1 and 2: Visit service URL (follows redirects automatically) and resolve any
            // OIDC bridge forms
            var (currentHTML, currentURL) = try await visit(serviceURL, session: session, generation: generation)

            // Step 3: Check if we're on the SSO login page. A live session would let a password the
            // user typed through unchecked, so that sign-in drops the service's cookies and goes on to
            // step 4, which ends the SSO session: the visit after it reaches the form.
            if interactive, !HTMLParser.isSSOLoginPage(html: currentHTML, url: currentURL) {
                NTUSTSessionManager.shared.dropServiceCookies(for: serviceURL)
            } else if !HTMLParser.isSSOLoginPage(html: currentHTML, url: currentURL) {
                if try await isSignedIn(html: currentHTML, url: currentURL, session: session) { return true }
                // A service whose own session lapsed sends the visit to the campus portal, not to
                // the sign-in form; without its cookies the next visit goes through SSO.
                NTUSTSessionManager.shared.dropServiceCookies(for: serviceURL)
                (currentHTML, currentURL) = try await visit(serviceURL, session: session, generation: generation)
                if !HTMLParser.isSSOLoginPage(html: currentHTML, url: currentURL) {
                    guard try await isSignedIn(html: currentHTML, url: currentURL, session: session) else {
                        throw SSOLoginError.loginFormNotFound
                    }
                    return true
                }
            }

            if !interactive, storedPasswordPostMustWait(now: now()) { throw SSOLoginError.loginFailed(reason: nil) }

            // Step 4: Clear only the SSO cookies; keeping Moodle and service cookies avoids
            // device-change warnings. They are in the session's jar, the NTUST-private one:
            // clearing `HTTPCookieStorage.shared` would miss them and only hurt unrelated callers.
            let jar = session.configuration.httpCookieStorage
            jar?.cookies?
                .filter { $0.domain.contains("ssoam2.ntust.edu.tw") }
                .forEach { jar?.deleteCookie($0) }

            // Re-visit service URL
            let (data2, response2) = try await session.data(from: serviceURL)
            guard let resp2 = response2 as? HTTPURLResponse,
                  let html2 = decodeHTML(data2, response: resp2) else {
                throw SSOLoginError.invalidResponse
            }
            currentURL = resp2.url ?? serviceURL
            currentHTML = html2

            if !HTMLParser.isSSOLoginPage(html: currentHTML, url: currentURL) {
                (currentHTML, currentURL) = try await resolveOIDCBridgeForms(
                    session: session, html: currentHTML, baseURL: currentURL, generation: generation
                )
                guard try await isSignedIn(html: currentHTML, url: currentURL, session: session) else {
                    throw SSOLoginError.loginFormNotFound
                }
                return true
            }

            // Step 5: Submit SSO login form
            guard let form = HTMLParser.findFormById(currentHTML, id: "loginForm") else {
                throw SSOLoginError.loginFormNotFound
            }

            var payload: [(String, String)] = form.inputs
            replaceOrAppend(&payload, name: "Username", value: studentId)
            replaceOrAppend(&payload, name: "Password", value: password)
            if !payload.contains(where: { $0.0 == "captcha" }) {
                payload.append(("captcha", ""))
            }

            let actionURL = resolveURL(form.action, base: currentURL)
            // Nothing is posted, so the sign-in does not ask the user to check the password.
            guard CredentialPost.isSignInTarget(actionURL) else {
                AppLogger.auth.error(
                    "Sign-in form action refused: \(CredentialPost.schemeLabel(of: actionURL), privacy: .public) \(actionURL.host ?? "", privacy: .private)"
                )
                throw SSOLoginError.invalidResponse
            }
            let (loginData, loginResponse) = try await postForm(
                session: session, url: actionURL, fields: payload, generation: generation,
                delegate: CredentialPostDelegate()
            )
            // The POST stops at a redirect it may not follow (`CredentialPostDelegate`), which is no
            // answer to the sign-in, and no refusal of the password either.
            guard let loginResp = loginResponse as? HTTPURLResponse,
                  !(300..<400).contains(loginResp.statusCode),
                  let loginHTML = decodeHTML(loginData, response: loginResp) else {
                throw SSOLoginError.invalidResponse
            }
            currentURL = loginResp.url ?? actionURL
            currentHTML = loginHTML

            // Step 6: Resolve OIDC bridge forms after login
            (currentHTML, currentURL) = try await resolveOIDCBridgeForms(
                session: session, html: currentHTML, baseURL: currentURL, generation: generation
            )

            // Step 7: Check if still on SSO page → login failed
            if HTMLParser.isSSOLoginPage(html: currentHTML, url: currentURL) {
                if !interactive, NTUSTSessionManager.shared.generation == generation {
                    noteStoredPasswordRefused(at: now())
                }
                throw SSOLoginError.loginFailed(reason: HTMLParser.loginErrorMessage(in: currentHTML))
            }

            guard try await isSignedIn(html: currentHTML, url: currentURL, session: session) else {
                throw SSOLoginError.invalidResponse
            }
            // The school took the stored password. A live session that lets a sign-in through
            // without a post says nothing of the password, so those returns leave the refusals.
            if !interactive { forgetStoredPasswordRefusals() }
            return true
        } catch SSOLoginError.loginFailed(let reason) {
            throw SSOLoginError.loginFailed(reason: reason)
        } catch {
            if !AppLogger.isCancellation(error) { logFailure(error) }
            throw error
        }
    }

    private static func visit(_ url: URL, session: URLSession, generation: Int) async throws -> (String, URL) {
        let (data, response) = try await session.data(from: url)
        guard let httpResp = response as? HTTPURLResponse,
              let html = decodeHTML(data, response: httpResp) else {
            throw SSOLoginError.invalidResponse
        }
        return try await resolveOIDCBridgeForms(
            session: session, html: html, baseURL: httpResp.url ?? url, generation: generation
        )
    }

    /// Whether a page that is not the ssoam2 form came with a live SSO session. A maintenance
    /// page, an error page or the campus portal lands here as well as the service itself.
    private static func isSignedIn(html: String, url: URL, session: URLSession) async throws -> Bool {
        if HTMLParser.isNetIQLoginPage(html: html, url: url) {
            throw SSOLoginError.interactiveLoginRequired
        }
        guard await NTUSTSessionManager.shared.probeCookiesValid(using: session) else { return false }
        NTUSTSessionManager.shared.markLoginSuccess()
        return true
    }

    /// Follow OIDC bridge form chain (max 3 steps), mirroring Python's _resolve_oidc_bridge_forms
    private static func resolveOIDCBridgeForms(
        session: URLSession,
        html: String,
        baseURL: URL,
        generation: Int,
        maxSteps: Int = 3
    ) async throws -> (String, URL) {
        var currentHTML = html
        var currentURL = baseURL

        for _ in 0..<maxSteps {
            if HTMLParser.isSSOLoginPage(html: currentHTML, url: currentURL) {
                return (currentHTML, currentURL)
            }

            guard let form = HTMLParser.findOIDCBridgeForm(currentHTML) else {
                return (currentHTML, currentURL)
            }

            let actionURL = resolveURL(form.action, base: currentURL)
            guard CredentialPost.isSchoolTarget(actionURL) else {
                AppLogger.auth.error(
                    "Sign-in bridge form action refused: \(CredentialPost.schemeLabel(of: actionURL), privacy: .public) \(actionURL.host ?? "", privacy: .private)"
                )
                throw SSOLoginError.invalidResponse
            }
            let (data, response) = try await postForm(
                session: session, url: actionURL, fields: form.inputs, generation: generation,
                delegate: CredentialPostDelegate()
            )
            // Stopped at a redirect it may not follow: the service got nothing, though a live SSO
            // session would let the sign-in pass for done. Checked before the body, whatever it is.
            if let resp = response as? HTTPURLResponse, (300..<400).contains(resp.statusCode) {
                throw SSOLoginError.invalidResponse
            }
            guard let newHTML = String(data: data, encoding: .utf8),
                  let resp = response as? HTTPURLResponse else {
                return (currentHTML, currentURL)
            }
            currentURL = resp.url ?? actionURL
            currentHTML = newHTML
        }

        return (currentHTML, currentURL)
    }

    /// POST form-encoded data. Each POST signs in, with the credentials or an OIDC form, so it
    /// stops once a sign-out moves the generation. `delegate` is the task's, for the
    /// credentials' POST a `CredentialPostDelegate`.
    private static func postForm(
        session: URLSession,
        url: URL,
        fields: [(name: String, value: String)],
        generation: Int,
        delegate: (any URLSessionTaskDelegate & Sendable)? = nil
    ) async throws -> (Data, URLResponse) {
        try checkSignedIn(generation)
        // 15 s matches NTUSTSessionManager's `timeoutIntervalForRequest`. Without it the
        // request takes `URLRequest`'s 60 s default and the configuration's 7-day resource
        // timeout, so a stalled SSO server could hang the login Task indefinitely.
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formBody(fields).utf8)

        return try await session.data(for: request, delegate: delegate)
    }

    static func formBody(_ fields: [(name: String, value: String)]) -> String {
        fields.map { "\(urlEncode($0.name))=\(urlEncode($0.value))" }.joined(separator: "&")
    }

    /// Form-encode a single name or value per
    /// `application/x-www-form-urlencoded` rules:
    /// percent-encode every byte outside RFC-3986 unreserved, then map
    /// space → `+`. This keeps passwords containing `+ & = / ; %` and
    /// CJK characters from being silently corrupted.
    private static let formAllowed: CharacterSet = {
        CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
    }()

    private static func urlEncode(_ string: String) -> String {
        // On encoder failure return "" rather than the raw string: the value is a username or
        // password, and silently sending its cleartext bytes is far worse than a failed login.
        guard let percentEncoded = string
            .addingPercentEncoding(withAllowedCharacters: formAllowed) else {
            assertionFailure("urlEncode failed for value of length \(string.count)")
            return ""
        }
        return percentEncoded.replacingOccurrences(of: "%20", with: "+")
    }

    private static func resolveURL(_ path: String, base: URL) -> URL {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path) ?? base
        }
        return URL(string: path, relativeTo: base)?.absoluteURL ?? base
    }

    private static func replaceOrAppend(_ fields: inout [(String, String)], name: String, value: String) {
        if let idx = fields.firstIndex(where: { $0.0 == name }) {
            fields[idx] = (name, value)
        } else {
            fields.append((name, value))
        }
    }
}
