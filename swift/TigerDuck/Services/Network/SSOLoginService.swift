import Foundation

enum SSOLoginError: LocalizedError {
    case loginFormNotFound
    case loginFailed
    case networkError(Error)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .loginFormNotFound: return "找不到 SSO 登入表單"
        case .loginFailed: return "登入失敗，請確認帳號密碼"
        case .networkError(let e): return "網路錯誤：\(e.localizedDescription)"
        case .invalidResponse: return "伺服器回應異常"
        }
    }
}

enum SSOLoginService {

    /// Ensure the user is logged in to the given service via NTUST SSO.
    /// Mirrors the Python `NtustSsoBridge.ensure_service_login` flow.
    static func ensureServiceLogin(
        session: URLSession,
        serviceURL: URL,
        studentId: String,
        password: String
    ) async throws -> Bool {
        do {
            // Step 1: Visit service URL (follows redirects automatically)
            let (data, response) = try await session.data(from: serviceURL)
            guard let httpResp = response as? HTTPURLResponse,
                  let html = String(data: data, encoding: .utf8) else {
                throw SSOLoginError.invalidResponse
            }
            let finalURL = httpResp.url ?? serviceURL

            // Step 2: Resolve any OIDC bridge forms
            var currentHTML = html
            var currentURL = finalURL
            (currentHTML, currentURL) = try await resolveOIDCBridgeForms(
                session: session, html: currentHTML, baseURL: currentURL
            )

            // Step 3: Check if we're on the SSO login page
            if !HTMLParser.isSSOLoginPage(html: currentHTML, url: currentURL) {
                NTUSTSessionManager.shared.markLoginSuccess()
                return true
            }

            // Step 4: Clear SSO cookies only (preserve Moodle/service cookies to avoid device-change warnings)
            HTTPCookieStorage.shared.cookies?
                .filter { $0.domain.contains("ssoam2.ntust.edu.tw") }
                .forEach { HTTPCookieStorage.shared.deleteCookie($0) }

            // Re-visit service URL
            let (data2, response2) = try await session.data(from: serviceURL)
            guard let html2 = String(data: data2, encoding: .utf8),
                  let resp2 = response2 as? HTTPURLResponse else {
                throw SSOLoginError.invalidResponse
            }
            currentURL = resp2.url ?? serviceURL
            currentHTML = html2

            if !HTMLParser.isSSOLoginPage(html: currentHTML, url: currentURL) {
                (currentHTML, currentURL) = try await resolveOIDCBridgeForms(
                    session: session, html: currentHTML, baseURL: currentURL
                )
                NTUSTSessionManager.shared.markLoginSuccess()
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
            let (loginData, loginResponse) = try await postForm(
                session: session, url: actionURL, fields: payload
            )
            guard let loginHTML = String(data: loginData, encoding: .utf8),
                  let loginResp = loginResponse as? HTTPURLResponse else {
                throw SSOLoginError.invalidResponse
            }
            currentURL = loginResp.url ?? actionURL
            currentHTML = loginHTML

            // Step 6: Resolve OIDC bridge forms after login
            (currentHTML, currentURL) = try await resolveOIDCBridgeForms(
                session: session, html: currentHTML, baseURL: currentURL
            )

            // Step 7: Check if still on SSO page → login failed
            if HTMLParser.isSSOLoginPage(html: currentHTML, url: currentURL) {
                throw SSOLoginError.loginFailed
            }

            NTUSTSessionManager.shared.markLoginSuccess()
            return true
        } catch SSOLoginError.loginFailed {
            throw SSOLoginError.loginFailed
        } catch {
            AppLogger.captureError(error, context: ["service": "ssoEnsureServiceLogin"])
            throw error
        }
    }

    /// Follow OIDC bridge form chain (max 3 steps), mirroring Python's _resolve_oidc_bridge_forms
    private static func resolveOIDCBridgeForms(
        session: URLSession,
        html: String,
        baseURL: URL,
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
            let (data, response) = try await postForm(
                session: session, url: actionURL, fields: form.inputs
            )
            guard let newHTML = String(data: data, encoding: .utf8),
                  let resp = response as? HTTPURLResponse else {
                return (currentHTML, currentURL)
            }
            currentURL = resp.url ?? actionURL
            currentHTML = newHTML
        }

        return (currentHTML, currentURL)
    }

    /// POST form-encoded data
    private static func postForm(
        session: URLSession,
        url: URL,
        fields: [(name: String, value: String)]
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = fields.map { name, value in
            "\(urlEncode(name))=\(urlEncode(value))"
        }.joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        return try await session.data(for: request)
    }

    private static func urlEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
            .replacingOccurrences(of: "+", with: "%2B")
            .replacingOccurrences(of: "&", with: "%26")
            .replacingOccurrences(of: "=", with: "%3D") ?? string
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
