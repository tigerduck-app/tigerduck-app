import Foundation

enum SSOLoginError: LocalizedError {
    case loginFormNotFound
    case loginFailed
    case networkError(Error)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .loginFormNotFound: return String(localized: "error_sso_sign_in_form_not_found")
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

    /// Hosts the SSO credential POST is allowed to target. A redirected /
    /// compromised upstream returning a `<form action="https://attacker/">`
    /// must never receive `Username=...&Password=...`, so we hard-fail any
    /// resolved action whose host is not in this set.
    private static let ssoActionHostAllowlist: Set<String> = [
        "ssoam2.ntust.edu.tw",
    ]

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
                  let html = decodeHTML(data, response: httpResp) else {
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

            // Step 4: Clear SSO cookies only (preserve Moodle/service cookies to avoid device-change warnings).
            // Cookies live in the NTUST-private jar — never touch
            // `HTTPCookieStorage.shared` here, which would now be a no-op
            // for NTUST and a foot-gun for unrelated callers.
            let ntustJar = NTUSTSessionManager.shared.cookieStorage
            ntustJar.cookies?
                .filter { $0.domain.contains("ssoam2.ntust.edu.tw") }
                .forEach { ntustJar.deleteCookie($0) }

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
            guard let actionHost = actionURL.host,
                  ssoActionHostAllowlist.contains(actionHost) else {
                AppLogger.captureError(
                    SSOLoginError.loginFailed,
                    context: [
                        "service": "ssoEnsureServiceLogin",
                        "rejectedActionHost": actionURL.host ?? "<nil>",
                    ]
                )
                throw SSOLoginError.loginFailed
            }
            let (loginData, loginResponse) = try await postForm(
                session: session, url: actionURL, fields: payload
            )
            guard let loginResp = loginResponse as? HTTPURLResponse,
                  let loginHTML = decodeHTML(loginData, response: loginResp) else {
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
        // 15 s per-request matches NTUSTSessionManager's session-level
        // `timeoutIntervalForRequest`. Without it the request inherits
        // `URLRequest`'s 60 s default and `URLSessionConfiguration`'s
        // 7-day `timeoutIntervalForResource`, so a stalled SSO server
        // could hang the login Task indefinitely.
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = fields.map { name, value in
            "\(urlEncode(name))=\(urlEncode(value))"
        }.joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        return try await session.data(for: request)
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
        // Encoder fallback returns "" rather than the raw string. The raw
        // string here is a username/password — silently shipping cleartext
        // bytes on the wire is far worse than a failed login attempt, so
        // an empty form value is the safer default.
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
