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

    static func ensureServiceLogin(
        session: URLSession,
        serviceURL: URL,
        studentId: String,
        password: String,
        isCurrent: @escaping @MainActor () -> Bool,
        interactive: Bool = false,
        now: () -> Date = { Date() },
        logFailure: @escaping @MainActor (any Error) -> Void = {
            AppLogger.captureError($0, context: ["service": "ssoEnsureServiceLogin"])
        }
    ) async throws -> Bool {
        guard !interactive else {
            return try await signIn(
                session: session, serviceURL: serviceURL, studentId: studentId, password: password,
                isCurrent: isCurrent, interactive: true, now: now, logFailure: logFailure
            )
        }
        return try await SchoolPasswordPosts.postingStoredPassword {
            try await signIn(
                session: session, serviceURL: serviceURL, studentId: studentId, password: password,
                isCurrent: isCurrent, interactive: false, now: now, logFailure: logFailure
            )
        }
    }

    /// ``ensureServiceLogin`` for the retry of a refused stored password. A live session lets an
    /// automatic sign-in through without a post, which says nothing about the password, so this
    /// ends the session as a typed sign-in does and posts. A refusal is counted, but a yes leaves
    /// the count to the caller, which forgets it once the rest of its retry went through. Once it
    /// holds the SSO locks it posts nothing while no refusal is counted, as a sign-in it waited
    /// behind may have settled it, nor while `mayPost` says no, as for a sign-in typed meanwhile,
    /// nor while a refusal's wait holds; the session then stays as it is.
    static func signInAgain(
        session: URLSession,
        serviceURL: URL,
        studentId: String,
        password: String,
        isCurrent: @escaping @MainActor () -> Bool,
        now: () -> Date = { Date() },
        mayPost: () -> Bool
    ) async throws -> Bool {
        try await SchoolPasswordPosts.postingStoredPassword {
            try await oneAtATime {
                try checkSignedIn(isCurrent)
                guard SchoolPasswordPosts.storedPasswordRefusals.count > 0 else { return true }
                guard mayPost() else { return false }
                if SchoolPasswordPosts.storedPasswordPostMustWait(now: now()) { throw SSOLoginError.loginFailed(reason: nil) }
                return try await performServiceLogin(
                    session: session, serviceURL: serviceURL, studentId: studentId, password: password,
                    isCurrent: isCurrent, interactive: false, retry: true, now: now,
                    logFailure: { AppLogger.captureError($0, context: ["service": "ssoSignInAgain"]) }
                )
            }
        }
    }

    private static func signIn(
        session: URLSession,
        serviceURL: URL,
        studentId: String,
        password: String,
        isCurrent: @escaping @MainActor () -> Bool,
        interactive: Bool,
        now: () -> Date,
        logFailure: @escaping @MainActor (any Error) -> Void
    ) async throws -> Bool {
        try await oneAtATime {
            try checkSignedIn(isCurrent)
            let signedIn = try await performServiceLogin(
                session: session, serviceURL: serviceURL, studentId: studentId, password: password,
                isCurrent: isCurrent, interactive: interactive, retry: false, now: now,
                logFailure: logFailure
            )
            if interactive, signedIn { SchoolPasswordPosts.forgetStoredPasswordRefusals() }
            return signedIn
        }
    }

    static func checkSignedIn(_ isCurrent: @MainActor () -> Bool) throws {
        if !isCurrent() { throw CancellationError() }
    }

    private static func performServiceLogin(
        session: URLSession,
        serviceURL: URL,
        studentId: String,
        password: String,
        isCurrent: @escaping @MainActor () -> Bool,
        interactive: Bool,
        retry: Bool,
        now: () -> Date,
        logFailure: @MainActor (any Error) -> Void
    ) async throws -> Bool {
        do {
            var (currentHTML, currentURL) = try await SSOForms.visit(serviceURL, session: session, isCurrent: isCurrent)

            // Step 3: Check if we're on the SSO login page. A live session would let the password
            // through unchecked, so a sign-in past it drops the service's cookies and goes on to
            // step 4, which ends the SSO session: the visit after it reaches the form.
            if interactive || retry, !HTMLParser.isSSOLoginPage(html: currentHTML, url: currentURL) {
                NTUSTSessionManager.shared.dropServiceCookies(for: serviceURL)
            } else if !HTMLParser.isSSOLoginPage(html: currentHTML, url: currentURL) {
                if try await isSignedIn(html: currentHTML, url: currentURL, session: session) { return true }
                // A service whose own session lapsed sends the visit to the campus portal, not to
                // the sign-in form; without its cookies the next visit goes through SSO.
                NTUSTSessionManager.shared.dropServiceCookies(for: serviceURL)
                (currentHTML, currentURL) = try await SSOForms.visit(serviceURL, session: session, isCurrent: isCurrent)
                if !HTMLParser.isSSOLoginPage(html: currentHTML, url: currentURL) {
                    guard try await isSignedIn(html: currentHTML, url: currentURL, session: session) else {
                        throw SSOLoginError.loginFormNotFound
                    }
                    return true
                }
            }

            if !interactive, SchoolPasswordPosts.storedPasswordPostMustWait(now: now()) { throw SSOLoginError.loginFailed(reason: nil) }

            // Step 4: Clear only the SSO cookies; keeping Moodle and service cookies avoids
            // device-change warnings. They are in the session's jar, the NTUST-private one:
            // clearing `HTTPCookieStorage.shared` would miss them and only hurt unrelated callers.
            let jar = session.configuration.httpCookieStorage
            jar?.cookies?
                .filter { $0.domain.contains("ssoam2.ntust.edu.tw") }
                .forEach { jar?.deleteCookie($0) }

            let (data2, response2) = try await session.data(from: serviceURL)
            guard let resp2 = response2 as? HTTPURLResponse,
                  let html2 = SSOForms.decodeHTML(data2, response: resp2) else {
                throw SSOLoginError.invalidResponse
            }
            currentURL = resp2.url ?? serviceURL
            currentHTML = html2

            if !HTMLParser.isSSOLoginPage(html: currentHTML, url: currentURL) {
                (currentHTML, currentURL) = try await SSOForms.resolveOIDCBridgeForms(
                    session: session, html: currentHTML, baseURL: currentURL, isCurrent: isCurrent
                )
                guard try await isSignedIn(html: currentHTML, url: currentURL, session: session) else {
                    throw SSOLoginError.loginFormNotFound
                }
                return true
            }

            guard let form = HTMLParser.findFormById(currentHTML, id: "loginForm") else {
                throw SSOLoginError.loginFormNotFound
            }

            var payload: [(String, String)] = form.inputs
            SSOForms.replaceOrAppend(&payload, name: "Username", value: studentId)
            SSOForms.replaceOrAppend(&payload, name: "Password", value: password)
            if !payload.contains(where: { $0.0 == "captcha" }) {
                payload.append(("captcha", ""))
            }

            let actionURL = SSOForms.resolveURL(form.action, base: currentURL)
            guard CredentialPost.isSignInTarget(actionURL) else {
                AppLogger.auth.error(
                    "Sign-in form action refused: \(CredentialPost.schemeLabel(of: actionURL), privacy: .public) \(actionURL.host ?? "", privacy: .private)"
                )
                throw SSOLoginError.invalidResponse
            }
            let (loginData, loginResponse) = try await SSOForms.postForm(
                session: session, url: actionURL, fields: payload, isCurrent: isCurrent,
                delegate: CredentialPostDelegate()
            )
            guard let loginResp = loginResponse as? HTTPURLResponse,
                  !(300..<400).contains(loginResp.statusCode),
                  let loginHTML = SSOForms.decodeHTML(loginData, response: loginResp) else {
                throw SSOLoginError.invalidResponse
            }
            currentURL = loginResp.url ?? actionURL
            currentHTML = loginHTML

            (currentHTML, currentURL) = try await SSOForms.resolveOIDCBridgeForms(
                session: session, html: currentHTML, baseURL: currentURL, isCurrent: isCurrent
            )

            if HTMLParser.isSSOLoginPage(html: currentHTML, url: currentURL) {
                if !interactive, isCurrent() {
                    SchoolPasswordPosts.noteStoredPasswordRefused(at: now())
                }
                throw SSOLoginError.loginFailed(reason: HTMLParser.loginErrorMessage(in: currentHTML))
            }

            guard try await isSignedIn(html: currentHTML, url: currentURL, session: session) else {
                throw SSOLoginError.invalidResponse
            }
            if !interactive, !retry { SchoolPasswordPosts.forgetStoredPasswordRefusals() }
            return true
        } catch SSOLoginError.loginFailed(let reason) {
            throw SSOLoginError.loginFailed(reason: reason)
        } catch {
            if !AppLogger.isCancellation(error) { logFailure(error) }
            throw error
        }
    }

    private static func isSignedIn(html: String, url: URL, session: URLSession) async throws -> Bool {
        if HTMLParser.isNetIQLoginPage(html: html, url: url) {
            throw SSOLoginError.interactiveLoginRequired
        }
        guard await NTUSTSessionManager.shared.probeCookiesValid(using: session) else { return false }
        NTUSTSessionManager.shared.markLoginSuccess()
        return true
    }
}
