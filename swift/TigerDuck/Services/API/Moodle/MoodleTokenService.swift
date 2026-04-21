import Foundation

/// Obtain and persist a Moodle Mobile App long-lived token via the NTUST
/// OIDC SSO launch flow. Verified against a real Moodle iOS App HAR dump
/// (2026-04-21).
///
/// WARNING — do NOT replace this flow with a POST to `/login/token.php`.
/// NTUST Moodle authenticates via OIDC-only (auth_oidc plugin); the
/// local-password token endpoint counts every request as a failed login
/// and triggers `login_lockout`, banning the account within ~10 attempts.
///
/// HAR-aligned steps:
///   [1] GET  moodle2/admin/tool/mobile/launch.php?service=&passport=&urlscheme=
///   [2] auto-follow 303 → login/index.php → auth/oidc/
///   [3] auto-follow 303 → ssoam2/connect/authorize?... (OIDC PKCE)
///   [4] auto-follow 302 → ssoam2/account/login
///   [5] harvest __RequestVerificationToken + hidden fields
///   [6] POST ssoam2/  with credentials
///   [7] auto-follow 302 → ssoam2/connect/authorize returns form_post HTML
///   [8] POST moodle2/auth/oidc/  with (code, state, iss)
///   [9] auto-follow 303 → launch.php → launch.php?confirmed=0&oauthsso=0
///   [10] parse `moodlemobile://token=<base64>` from final HTML
///   [11] base64-decode → "<signature>:::<wstoken>:::<privatetoken>"
actor MoodleTokenService {
    static let shared = MoodleTokenService()

    private static let siteBaseURL = URL(string: "https://moodle2.ntust.edu.tw")!
    private static let ssoBaseURL = URL(string: "https://ssoam2.ntust.edu.tw")!
    private static let service = "moodle_mobile_app"
    private static let urlScheme = "moodlemobile"
    private static let mobileUA = (
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 "
        + "MoodleMobile 5.1.1 (51100)"
    )

    private var inFlightTokenTask: Task<String, Error>?
    private var inFlightRefreshTask: Task<String, Error>?

    private init() {}

    // MARK: - Public API

    /// Obtain a new Moodle webservice token using explicit credentials.
    /// Concurrent calls share the same in-flight task.
    func obtainToken(studentId: String, password: String) async throws -> String {
        if let existing = inFlightTokenTask {
            return try await existing.value
        }
        let normalizedId = studentId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let task = Task<String, Error> {
            let triple = try await Self.performOidcLogin(
                studentId: normalizedId, password: password,
            )
            await Self.persist(triple: triple)
            return triple.wstoken
        }
        inFlightTokenTask = task
        defer {
            task.cancel()
            inFlightTokenTask = nil
        }
        return try await task.value
    }

    /// Silently refresh the Moodle token using stored NTUST credentials.
    /// Concurrent calls share the same in-flight refresh task.
    func refreshTokenIfNeeded() async throws -> String {
        if let existing = inFlightRefreshTask {
            return try await existing.value
        }
        let task = Task<String, Error> {
            let creds = await MainActor.run {
                (
                    KeychainManager.loadString(key: AppConstants.KeychainKeys.studentId),
                    KeychainManager.loadString(key: AppConstants.KeychainKeys.password)
                )
            }
            guard let sid = creds.0, let pwd = creds.1 else {
                throw MoodleWebserviceError.invalidCredentials
            }
            let normalizedId = sid
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            let triple = try await Self.performOidcLogin(
                studentId: normalizedId, password: pwd,
            )
            await Self.persist(triple: triple)
            return triple.wstoken
        }
        inFlightRefreshTask = task
        defer {
            task.cancel()
            inFlightRefreshTask = nil
        }
        return try await task.value
    }

    /// Clear stored Moodle token. Called on logout.
    func clearToken() async {
        await MainActor.run {
            KeychainManager.delete(key: AppConstants.KeychainKeys.moodleToken)
            KeychainManager.delete(key: AppConstants.KeychainKeys.moodlePrivateToken)
        }
    }

    /// Return the currently stored token, or nil if none.
    func currentToken() async -> String? {
        await MainActor.run {
            KeychainManager.loadString(key: AppConstants.KeychainKeys.moodleToken)
        }
    }

    // MARK: - OIDC flow

    private struct TokenTriple: Sendable {
        let signature: String
        let wstoken: String
        let privatetoken: String?
    }

    private static func persist(triple: TokenTriple) async {
        await MainActor.run {
            KeychainManager.saveString(
                key: AppConstants.KeychainKeys.moodleToken,
                value: triple.wstoken,
            )
            if let pt = triple.privatetoken, !pt.isEmpty {
                KeychainManager.saveString(
                    key: AppConstants.KeychainKeys.moodlePrivateToken,
                    value: pt,
                )
            } else {
                KeychainManager.delete(
                    key: AppConstants.KeychainKeys.moodlePrivateToken,
                )
            }
        }
    }

    private static func performOidcLogin(
        studentId: String,
        password: String
    ) async throws -> TokenTriple {
        // Dedicated session with an isolated per-flow cookie jar.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.httpCookieStorage = HTTPCookieStorage()
        config.httpAdditionalHeaders = [
            "User-Agent": mobileUA,
            "Accept":
                "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-TW,zh;q=0.9,en-US;q=0.8,en;q=0.7",
        ]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        // Step 1: GET launch.php — URLSession auto-follows 303s to SSO login.
        let passport = Double.random(in: 0..<1) * 1000
        var launchComps = URLComponents(
            url: siteBaseURL.appendingPathComponent("admin/tool/mobile/launch.php"),
            resolvingAgainstBaseURL: false,
        )!
        launchComps.queryItems = [
            URLQueryItem(name: "service", value: service),
            URLQueryItem(name: "passport", value: String(passport)),
            URLQueryItem(name: "urlscheme", value: urlScheme),
        ]
        guard let launchURL = launchComps.url else {
            throw MoodleWebserviceError.malformedResponse(detail: "invalid launch URL")
        }
        let (loginData, loginResp) = try await dataTask(session: session, request: URLRequest(url: launchURL))
        try assertOK(response: loginResp, data: loginData)
        guard let loginURL = (loginResp as? HTTPURLResponse)?.url,
              loginURL.host?.contains("ssoam2.ntust.edu.tw") == true else {
            throw MoodleWebserviceError.malformedResponse(detail: "expected SSO login page")
        }
        let loginHTML = String(data: loginData, encoding: .utf8) ?? ""
        let fields = parseSSOLoginFields(from: loginHTML)
        guard !fields.antiforgery.isEmpty else {
            throw MoodleWebserviceError.malformedResponse(
                detail: "AntiForgery token missing — SSO login page shape changed",
            )
        }

        // Step 6: POST credentials to ssoam2.ntust.edu.tw/
        let postURL = URL(string: fields.action, relativeTo: loginURL)?
            .absoluteURL ?? ssoBaseURL
        var postReq = URLRequest(url: postURL)
        postReq.httpMethod = "POST"
        postReq.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type",
        )
        postReq.setValue(loginURL.absoluteString, forHTTPHeaderField: "Referer")
        postReq.setValue(
            ssoBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            forHTTPHeaderField: "Origin",
        )
        postReq.httpBody = urlEncodedForm([
            "__RequestVerificationToken": fields.antiforgery,
            "Username": studentId,
            "Password": password,
            "captcha": "",
            "cf-turnstile-response": "",
            "h-captcha-response": "",
            "g-recaptcha-response": "",
            "ClientId": fields.clientId,
            "ReturnUrl": fields.returnUrl,
            "Uri": fields.uri,
        ])
        let (bridgeData, bridgeResp) = try await dataTask(session: session, request: postReq)
        try assertOK(response: bridgeResp, data: bridgeData)

        // Landing back on /account/login means credentials were rejected.
        if let url = (bridgeResp as? HTTPURLResponse)?.url?.absoluteString,
           url.contains("/account/login") {
            throw MoodleWebserviceError.invalidCredentials
        }

        // Step 8: POST code/state/iss to moodle2.ntust.edu.tw/auth/oidc/
        let bridgeHTML = String(data: bridgeData, encoding: .utf8) ?? ""
        guard let bridge = parseOIDCBridge(from: bridgeHTML) else {
            throw MoodleWebserviceError.malformedResponse(
                detail: "OIDC form_post bridge missing after login",
            )
        }
        guard let bridgeActionURL = URL(string: bridge.action, relativeTo: loginURL)?.absoluteURL else {
            throw MoodleWebserviceError.malformedResponse(
                detail: "invalid bridge action URL",
            )
        }
        var bridgeReq = URLRequest(url: bridgeActionURL)
        bridgeReq.httpMethod = "POST"
        bridgeReq.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type",
        )
        bridgeReq.httpBody = urlEncodedForm(bridge.payload)
        let (finalData, finalResp) = try await dataTask(session: session, request: bridgeReq)
        try assertOK(response: finalResp, data: finalData)

        // Step 10: extract moodlemobile://token=<base64>
        let finalHTML = String(data: finalData, encoding: .utf8) ?? ""
        guard let b64 = extractMoodleMobileToken(from: finalHTML) else {
            throw MoodleWebserviceError.malformedResponse(
                detail: "moodlemobile://token= scheme missing from final launch page",
            )
        }
        guard let decodedData = Data(base64Encoded: b64),
              let decoded = String(data: decodedData, encoding: .ascii) else {
            throw MoodleWebserviceError.malformedResponse(
                detail: "failed to base64-decode token triple",
            )
        }
        let parts = decoded.components(separatedBy: ":::")
        guard parts.count == 3 else {
            throw MoodleWebserviceError.malformedResponse(
                detail: "unexpected token triple (got \(parts.count) parts)",
            )
        }
        return TokenTriple(
            signature: parts[0],
            wstoken: parts[1],
            privatetoken: parts[2].isEmpty ? nil : parts[2],
        )
    }

    // MARK: - Networking helper

    private static func dataTask(
        session: URLSession,
        request: URLRequest,
    ) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let urlError as URLError {
            throw MoodleWebserviceError.transientNetwork(
                underlying: urlError.localizedDescription,
            )
        }
    }

    private static func assertOK(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MoodleWebserviceError.transientNetwork(
                underlying: "No HTTP response",
            )
        }
        if http.statusCode != 200 {
            if let moodleError = MoodleWebserviceError.from(jsonData: data) {
                throw moodleError
            }
            throw MoodleWebserviceError.httpStatus(code: http.statusCode)
        }
    }

    private static func urlEncodedForm(_ fields: [String: String]) -> Data? {
        // RFC-3986-unreserved only; anything else gets percent-encoded.
        // Conservative so passwords/tokens with `+ @ & = ? /` etc. are safe.
        let unreserved = CharacterSet(
            charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~",
        )
        let pairs: [String] = fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: unreserved) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
            return "\(k)=\(v)"
        }
        return pairs.joined(separator: "&").data(using: .utf8)
    }

    // MARK: - HTML parsers

    private struct SSOLoginFields {
        let action: String
        let antiforgery: String
        let clientId: String
        let returnUrl: String
        let uri: String
    }

    private struct OIDCBridge {
        let action: String
        let payload: [String: String]
    }

    private static func parseSSOLoginFields(from html: String) -> SSOLoginFields {
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        let formRe = try! NSRegularExpression(
            pattern: "<form[^>]*>([\\s\\S]+?)</form>",
            options: [.caseInsensitive],
        )
        var action = "/"
        var fields: [String: String] = [:]
        formRe.enumerateMatches(in: html, options: [], range: range) { match, _, stop in
            guard let m = match, m.numberOfRanges >= 2 else { return }
            let formFull = ns.substring(with: m.range)
            let formBody = ns.substring(with: m.range(at: 1))
            let names = extractInputNames(from: formBody)
            if names.contains("Username") && names.contains("Password") {
                action = extractFormAction(from: formFull) ?? "/"
                fields = extractInputPairs(from: formBody)
                stop.pointee = true
            }
        }
        return SSOLoginFields(
            action: action,
            antiforgery: fields["__RequestVerificationToken"] ?? "",
            clientId: fields["ClientId"] ?? "",
            returnUrl: fields["ReturnUrl"] ?? "",
            uri: fields["Uri"] ?? "",
        )
    }

    private static func parseOIDCBridge(from html: String) -> OIDCBridge? {
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        let formRe = try! NSRegularExpression(
            pattern: "<form[^>]*>([\\s\\S]+?)</form>",
            options: [.caseInsensitive],
        )
        var result: OIDCBridge?
        formRe.enumerateMatches(in: html, options: [], range: range) { match, _, stop in
            guard let m = match, m.numberOfRanges >= 2 else { return }
            let formFull = ns.substring(with: m.range)
            let formBody = ns.substring(with: m.range(at: 1))
            guard let action = extractFormAction(from: formFull) else {
                return
            }
            let payload = extractInputPairs(from: formBody)
            let isOidcAction = action.contains("/auth/oidc")
                || action.contains("moodle2.ntust.edu.tw/auth/oidc")
            if isOidcAction,
                payload["code"] != nil
                && payload["state"] != nil
                && payload["iss"] != nil {
                result = OIDCBridge(action: action, payload: payload)
                stop.pointee = true
            }
        }
        return result
    }

    private static func extractFormAction(from formTag: String) -> String? {
        let re = try! NSRegularExpression(
            pattern: "<form[^>]*action=[\"']([^\"']+)[\"']",
            options: [.caseInsensitive],
        )
        let ns = formTag as NSString
        guard let m = re.firstMatch(
            in: formTag,
            options: [],
            range: NSRange(location: 0, length: ns.length),
        ), m.numberOfRanges >= 2 else {
            return nil
        }
        return ns.substring(with: m.range(at: 1))
    }

    private static func extractInputNames(from html: String) -> Set<String> {
        let re = try! NSRegularExpression(
            pattern: "<input[^>]*name=[\"']([^\"']+)[\"']",
            options: [.caseInsensitive],
        )
        let ns = html as NSString
        var names = Set<String>()
        re.enumerateMatches(
            in: html,
            options: [],
            range: NSRange(location: 0, length: ns.length),
        ) { match, _, _ in
            guard let m = match, m.numberOfRanges >= 2 else { return }
            names.insert(ns.substring(with: m.range(at: 1)))
        }
        return names
    }

    private static func extractInputPairs(from html: String) -> [String: String] {
        let tagRe = try! NSRegularExpression(
            pattern: "<input[^>]*>",
            options: [.caseInsensitive],
        )
        let nameRe = try! NSRegularExpression(
            pattern: "name=[\"']([^\"']+)[\"']",
            options: [.caseInsensitive],
        )
        let valueRe = try! NSRegularExpression(
            pattern: "value=[\"']([^\"']*)[\"']",
            options: [.caseInsensitive],
        )
        let ns = html as NSString
        var out: [String: String] = [:]
        tagRe.enumerateMatches(
            in: html,
            options: [],
            range: NSRange(location: 0, length: ns.length),
        ) { match, _, _ in
            guard let m = match else { return }
            let tag = ns.substring(with: m.range)
            let tagNs = tag as NSString
            let tagRange = NSRange(location: 0, length: tagNs.length)
            guard let nm = nameRe.firstMatch(in: tag, options: [], range: tagRange),
                  nm.numberOfRanges >= 2 else {
                return
            }
            let name = tagNs.substring(with: nm.range(at: 1))
            let value: String
            if let vm = valueRe.firstMatch(in: tag, options: [], range: tagRange),
               vm.numberOfRanges >= 2 {
                value = tagNs.substring(with: vm.range(at: 1))
            } else {
                value = ""
            }
            out[name] = decodeHTMLEntities(value)
        }
        return out
    }

    private static func extractMoodleMobileToken(from html: String) -> String? {
        let re = try! NSRegularExpression(
            pattern: "moodlemobile://token=([A-Za-z0-9+/=_-]+)",
            options: [],
        )
        let ns = html as NSString
        guard let m = re.firstMatch(
            in: html,
            options: [],
            range: NSRange(location: 0, length: ns.length),
        ), m.numberOfRanges >= 2 else {
            return nil
        }
        return ns.substring(with: m.range(at: 1))
    }

    private static func decodeHTMLEntities(_ s: String) -> String {
        var r = s
        r = r.replacingOccurrences(of: "&amp;", with: "&")
        r = r.replacingOccurrences(of: "&quot;", with: "\"")
        r = r.replacingOccurrences(of: "&apos;", with: "'")
        r = r.replacingOccurrences(of: "&lt;", with: "<")
        r = r.replacingOccurrences(of: "&gt;", with: ">")
        r = r.replacingOccurrences(of: "&#x2F;", with: "/")
        r = r.replacingOccurrences(of: "&#x27;", with: "'")
        r = r.replacingOccurrences(of: "&#39;", with: "'")
        return r
    }
}
