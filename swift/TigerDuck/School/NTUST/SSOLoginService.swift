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
    enum SignInAgainOutcome: Equatable {
        case signedIn
        case refusalSettledMeanwhile
        case heldBack

        var leavesSchoolSignedIn: Bool { self != .heldBack }
    }

    private static let logins = AsyncSerialLock()

    static func oneAtATime<T>(_ body: () async throws -> T) async rethrows -> T {
        await logins.acquire()
        do {
            let result = try await body()
            await logins.release()
            return result
        } catch {
            await logins.release()
            throw error
        }
    }

    static func ensureServiceLogin(
        session: URLSession,
        serviceURL: URL,
        studentId: String,
        password: String,
        for signIn: SignIn,
        interactive: Bool = false,
        now: () -> Date = { Date() },
        logFailure: @escaping @MainActor (any Error) -> Void = {
            AppLogger.captureError($0, context: ["service": "ssoEnsureServiceLogin"])
        }
    ) async throws -> Bool {
        guard !interactive else {
            return try await Self.signIn(
                session: session, serviceURL: serviceURL, studentId: studentId, password: password,
                signIn: signIn, interactive: true, now: now, logFailure: logFailure
            )
        }
        return try await SchoolPasswordPosts.postingStoredPassword {
            try await Self.signIn(
                session: session, serviceURL: serviceURL, studentId: studentId, password: password,
                signIn: signIn, interactive: false, now: now, logFailure: logFailure
            )
        }
    }

    static func signInAgain(
        session: URLSession,
        serviceURL: URL,
        studentId: String,
        password: String,
        for signIn: SignIn,
        now: () -> Date = { Date() },
        mayPost: () -> Bool
    ) async throws -> SignInAgainOutcome {
        try await SchoolPasswordPosts.postingStoredPassword {
            try await oneAtATime {
                try checkSignedIn(signIn)
                if let outcome = try outcomeWithoutPosting(mayPost: mayPost, now: now()) { return outcome }
                try await performServiceLogin(
                    session: session, serviceURL: serviceURL, studentId: studentId, password: password,
                    signIn: signIn, interactive: false, retry: true, now: now,
                    logFailure: { AppLogger.captureError($0, context: ["service": "ssoSignInAgain"]) }
                )
                return .signedIn
            }
        }
    }

    private static func outcomeWithoutPosting(mayPost: () -> Bool, now: Date) throws -> SignInAgainOutcome? {
        guard SchoolPasswordPosts.storedPasswordRefusals.count > 0 else { return .refusalSettledMeanwhile }
        guard mayPost() else { return .heldBack }
        if SchoolPasswordPosts.storedPasswordPostMustWait(now: now) { throw SSOLoginError.loginFailed(reason: nil) }
        return nil
    }

    private static func signIn(
        session: URLSession,
        serviceURL: URL,
        studentId: String,
        password: String,
        signIn: SignIn,
        interactive: Bool,
        now: () -> Date,
        logFailure: @escaping @MainActor (any Error) -> Void
    ) async throws -> Bool {
        try await oneAtATime {
            try checkSignedIn(signIn)
            try await performServiceLogin(
                session: session, serviceURL: serviceURL, studentId: studentId, password: password,
                signIn: signIn, interactive: interactive, retry: false, now: now,
                logFailure: logFailure
            )
            if interactive { SchoolPasswordPosts.forgetStoredPasswordRefusals() }
            return true
        }
    }

    static func checkSignedIn(_ signIn: SignIn) throws {
        if !signIn.isCurrent { throw CancellationError() }
    }

    private static func performServiceLogin(
        session: URLSession,
        serviceURL: URL,
        studentId: String,
        password: String,
        signIn: SignIn,
        interactive: Bool,
        retry: Bool,
        now: () -> Date,
        logFailure: @MainActor (any Error) -> Void
    ) async throws {
        do {
            let visit = ServiceVisit(serviceURL: serviceURL, session: session, signIn: signIn)
            if interactive || retry {
                try await visit.dropLiveServiceSession()
            } else if try await visit.findsSignedIn() {
                return
            }
            if !interactive, SchoolPasswordPosts.storedPasswordPostMustWait(now: now()) { throw SSOLoginError.loginFailed(reason: nil) }

            let (html, url) = try await visit.endSSOSessionAndVisit()
            guard HTMLParser.isSSOLoginPage(html: html, url: url) else {
                let (bridgedHTML, bridgedURL) = try await SSOForms.resolveOIDCBridgeForms(
                    session: session, html: html, baseURL: url, signIn: signIn
                )
                guard try await isSignedIn(html: bridgedHTML, url: bridgedURL, session: session, signIn: signIn) else {
                    throw SSOLoginError.loginFormNotFound
                }
                return
            }
            try await postSignInForm(
                html: html, url: url, studentId: studentId, password: password, visit: visit,
                interactive: interactive, now: now
            )
            if !interactive, !retry { SchoolPasswordPosts.forgetStoredPasswordRefusals() }
        } catch SSOLoginError.loginFailed(let reason) {
            throw SSOLoginError.loginFailed(reason: reason)
        } catch {
            if !AppLogger.isCancellation(error) { logFailure(error) }
            throw error
        }
    }

    private static func postSignInForm(
        html: String, url: URL, studentId: String, password: String, visit: ServiceVisit,
        interactive: Bool, now: () -> Date
    ) async throws {
        guard let form = HTMLParser.findFormById(html, id: "loginForm") else {
            throw SSOLoginError.loginFormNotFound
        }

        var payload: [(String, String)] = form.inputs
        SSOForms.replaceOrAppend(&payload, name: "Username", value: studentId)
        SSOForms.replaceOrAppend(&payload, name: "Password", value: password)
        if !payload.contains(where: { $0.0 == "captcha" }) {
            payload.append(("captcha", ""))
        }

        let actionURL = SSOForms.resolveURL(form.action, base: url)
        guard CredentialPost.isSignInTarget(actionURL) else {
            AppLogger.auth.error(
                "Sign-in form action refused: \(CredentialPost.schemeLabel(of: actionURL), privacy: .public) \(actionURL.host ?? "", privacy: .private)"
            )
            throw SSOLoginError.invalidResponse
        }
        let (session, signIn) = (visit.session, visit.signIn)
        let (loginData, loginResponse) = try await SSOForms.postForm(
            session: session, url: actionURL, fields: payload, signIn: signIn,
            delegate: CredentialPostDelegate()
        )
        guard let loginResp = loginResponse as? HTTPURLResponse,
              !(300..<400).contains(loginResp.statusCode),
              let loginHTML = SSOForms.decodeHTML(loginData, response: loginResp) else {
            throw SSOLoginError.invalidResponse
        }

        let (currentHTML, currentURL) = try await SSOForms.resolveOIDCBridgeForms(
            session: session, html: loginHTML, baseURL: loginResp.url ?? actionURL, signIn: signIn
        )

        if HTMLParser.isSSOLoginPage(html: currentHTML, url: currentURL) {
            if !interactive, signIn.isCurrent {
                SchoolPasswordPosts.noteStoredPasswordRefused(at: now())
            }
            throw SSOLoginError.loginFailed(reason: HTMLParser.loginErrorMessage(in: currentHTML))
        }

        guard try await isSignedIn(html: currentHTML, url: currentURL, session: session, signIn: signIn) else {
            throw SSOLoginError.invalidResponse
        }
    }

    fileprivate static func isSignedIn(html: String, url: URL, session: URLSession, signIn: SignIn) async throws -> Bool {
        if HTMLParser.isNetIQLoginPage(html: html, url: url) {
            throw SSOLoginError.interactiveLoginRequired
        }
        guard await NTUSTSessionManager.shared.probeCookiesValid(using: session, for: signIn) else { return false }
        NTUSTSessionManager.shared.markLoginSuccess(for: signIn)
        return true
    }
}

private struct ServiceVisit {
    let serviceURL: URL
    let session: URLSession
    let signIn: SignIn

    func dropLiveServiceSession() async throws {
        let (html, url) = try await SSOForms.visit(serviceURL, session: session, signIn: signIn)
        if !HTMLParser.isSSOLoginPage(html: html, url: url) {
            NTUSTSessionManager.shared.dropServiceCookies(for: serviceURL)
        }
    }

    func findsSignedIn() async throws -> Bool {
        let (html, url) = try await SSOForms.visit(serviceURL, session: session, signIn: signIn)
        guard !HTMLParser.isSSOLoginPage(html: html, url: url) else { return false }
        if try await SSOLoginService.isSignedIn(html: html, url: url, session: session, signIn: signIn) { return true }
        // A service whose own session lapsed sends the visit to the campus portal, not to
        // the sign-in form; without its cookies the next visit goes through SSO.
        NTUSTSessionManager.shared.dropServiceCookies(for: serviceURL)
        let (again, againURL) = try await SSOForms.visit(serviceURL, session: session, signIn: signIn)
        guard !HTMLParser.isSSOLoginPage(html: again, url: againURL) else { return false }
        guard try await SSOLoginService.isSignedIn(html: again, url: againURL, session: session, signIn: signIn) else {
            throw SSOLoginError.loginFormNotFound
        }
        return true
    }

    func endSSOSessionAndVisit() async throws -> (String, URL) {
        // Keeping Moodle and service cookies avoids device-change warnings.
        let jar = session.configuration.httpCookieStorage
        jar?.cookies?
            .filter { $0.domain.contains("ssoam2.ntust.edu.tw") }
            .forEach { jar?.deleteCookie($0) }

        let (data, response) = try await session.data(from: serviceURL)
        guard let http = response as? HTTPURLResponse,
              let html = SSOForms.decodeHTML(data, response: http) else {
            throw SSOLoginError.invalidResponse
        }
        return (html, http.url ?? serviceURL)
    }
}
