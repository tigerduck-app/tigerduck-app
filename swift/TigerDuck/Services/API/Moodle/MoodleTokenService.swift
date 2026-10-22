import Foundation

/// Obtains and persists a long-lived Moodle Mobile App token through the NTUST OIDC SSO
/// launch flow the Moodle iOS app uses: `launch.php`, the SSO login form, the OIDC
/// `form_post` back to Moodle, then `moodlemobile://token=<base64>` on the final page.
///
/// Never POST to `/login/token.php` instead. NTUST Moodle is OIDC-only (auth_oidc), and that
/// endpoint counts every request as a failed login and triggers `login_lockout`, banning the
/// account within about 10 attempts. See docs/decisions/0019-moodle-oidc-token-flow.md.
actor MoodleTokenService {
    static let shared = MoodleTokenService(
        storedCredentials: {
            guard let studentId = KeychainManager.loadString(key: AppConstants.KeychainKeys.studentId),
                  let password = KeychainManager.loadString(key: AppConstants.KeychainKeys.password) else {
                return nil
            }
            return (studentId, password)
        },
        tokens: .keychain,
        harvest: { try await performOidcLogin(studentId: $0, password: $1) }
    )

    private let storedCredentials: @Sendable () -> (studentId: String, password: String)?
    private let tokens: TokenStore
    private let harvest: @Sendable (_ studentId: String, _ password: String) async throws -> TokenTriple
    private let now: @Sendable () -> Date

    struct TokenStore: Sendable {
        let load: @Sendable () -> String?
        let save: @Sendable (TokenTriple) -> Void
        let drop: @Sendable () -> Void

        static let keychain = TokenStore(
            load: { KeychainManager.loadString(key: AppConstants.KeychainKeys.moodleToken) },
            save: { triple in
                KeychainManager.saveString(key: AppConstants.KeychainKeys.moodleToken, value: triple.wstoken)
                if let pt = triple.privatetoken, !pt.isEmpty {
                    KeychainManager.saveString(key: AppConstants.KeychainKeys.moodlePrivateToken, value: pt)
                } else {
                    KeychainManager.delete(key: AppConstants.KeychainKeys.moodlePrivateToken)
                }
            },
            drop: {
                KeychainManager.delete(key: AppConstants.KeychainKeys.moodleToken)
                KeychainManager.delete(key: AppConstants.KeychainKeys.moodlePrivateToken)
            }
        )
    }

    private static let ssoBaseURL = URL(string: "https://ssoam2.ntust.edu.tw")!
    private static let service = "moodle_mobile_app"
    private static let urlScheme = "moodlemobile"
    private static let mobileUA = (
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 "
        + "MoodleMobile 5.1.1 (51100)"
    )

    private struct ObtainKey: Hashable {
        let studentId: String
        let passwordHash: Int
    }
    private var inFlightTokenTask: (key: ObtainKey, task: Task<String, Error>)?
    private var inFlightRefreshTask: Task<String, Error>?
    private var signInGeneration = 0
    private var lastHarvestFailure: (at: Date, error: any Error)?
    nonisolated static let harvestPause: TimeInterval = 5 * 60

    private static let formBlockRegex = try! NSRegularExpression(
        pattern: "<form[^>]*>([\\s\\S]+?)</form>",
        options: [.caseInsensitive]
    )
    private static let formActionRegex = try! NSRegularExpression(
        pattern: "<form[^>]*action=[\"']([^\"']+)[\"']",
        options: [.caseInsensitive]
    )
    private static let inputNameRegex = try! NSRegularExpression(
        pattern: "<input[^>]*name=[\"']([^\"']+)[\"']",
        options: [.caseInsensitive]
    )
    private static let inputTagRegex = try! NSRegularExpression(
        pattern: "<input[^>]*>",
        options: [.caseInsensitive]
    )
    private static let inputNameAttrRegex = try! NSRegularExpression(
        pattern: "name=[\"']([^\"']+)[\"']",
        options: [.caseInsensitive]
    )
    private static let inputValueAttrRegex = try! NSRegularExpression(
        pattern: "value=[\"']([^\"']*)[\"']",
        options: [.caseInsensitive]
    )
    private static let moodleMobileTokenRegex = try! NSRegularExpression(
        pattern: #"["']moodlemobile://token=([A-Za-z0-9+/=_-]+)["']"#,
        options: []
    )
    init(
        storedCredentials: @escaping @Sendable () -> (studentId: String, password: String)?,
        tokens: TokenStore,
        harvest: @escaping @Sendable (_ studentId: String, _ password: String) async throws -> TokenTriple,
        now: @escaping @Sendable () -> Date = { Date() },
        harvestDeadline: Duration = MoodleTokenService.harvestDeadline
    ) {
        self.storedCredentials = storedCredentials
        self.tokens = tokens
        self.harvest = { studentId, password in
            try await Self.withinDeadline(harvestDeadline) { try await harvest(studentId, password) }
        }
        self.now = now
    }

    nonisolated static let harvestDeadline: Duration = .seconds(60)

    private nonisolated static func withinDeadline<T: Sendable>(
        _ deadline: Duration, _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw MoodleWebserviceError.transientNetwork(underlying: URLError(.timedOut).localizedDescription)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    func obtainToken(studentId: String, password: String) async throws -> String {
        let normalizedId = studentId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let key = ObtainKey(studentId: normalizedId, passwordHash: password.hashValue)
        if let existing = inFlightTokenTask {
            if existing.key == key {
                return try await existing.task.value
            }
            _ = try? await existing.task.value
        }
        let generation = signInGeneration
        let task = Task<String, Error> {
            let triple = try await harvest(normalizedId, password)
            guard signInGeneration == generation else { throw CancellationError() }
            tokens.save(triple)
            lastHarvestFailure = nil
            return triple.wstoken
        }
        inFlightTokenTask = (key, task)
        defer {
            if inFlightTokenTask?.task == task { inFlightTokenTask = nil }
        }
        return try await task.value
    }

    func refreshTokenIfNeeded(replacing rejected: String? = nil) async throws -> String {
        if let existing = inFlightRefreshTask {
            return try await existing.value
        }
        if let current = tokens.load() {
            guard current == rejected else { return current }
            tokens.drop()
        }
        guard !SSOLoginService.storedPasswordPostMustWait(now: now()) else {
            throw MoodleWebserviceError.ssoLoginRejected(reason: nil)
        }
        if let failure = lastHarvestFailure,
           case let age = now().timeIntervalSince(failure.at), age >= 0, age < Self.harvestPause {
            throw failure.error
        }
        let generation = signInGeneration
        let task = Task<String, Error> {
            let triple = try await SSOLoginService.postingStoredPassword {
                try await harvestWithStoredCredentials(generation: generation)
            }
            guard signInGeneration == generation else { throw CancellationError() }
            tokens.save(triple)
            lastHarvestFailure = nil
            if triple.postedPassword { SSOLoginService.forgetStoredPasswordRefusals() }
            return triple.wstoken
        }
        inFlightRefreshTask = task
        defer {
            if inFlightRefreshTask == task { inFlightRefreshTask = nil }
        }
        return try await task.value
    }

    private func harvestWithStoredCredentials(generation: Int) async throws -> TokenTriple {
        guard signInGeneration == generation else { throw CancellationError() }
        guard !SSOLoginService.storedPasswordPostMustWait(now: now()) else {
            throw MoodleWebserviceError.ssoLoginRejected(reason: nil)
        }
        guard let creds = storedCredentials() else {
            throw MoodleWebserviceError.missingStoredCredentials
        }
        let normalizedId = creds.studentId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        do {
            return try await harvest(normalizedId, creds.password)
        } catch {
            if case MoodleWebserviceError.ssoLoginRejected = error {
                if signInGeneration == generation, storedCredentials()?.password == creds.password {
                    SSOLoginService.noteStoredPasswordRefused(at: now())
                }
            } else if signInGeneration == generation, !Self.isNetworkFailure(error) {
                lastHarvestFailure = (now(), error)
            }
            throw error
        }
    }

    private static func isNetworkFailure(_ error: any Error) -> Bool {
        if case MoodleWebserviceError.transientNetwork = error { return true }
        return false
    }

    func signOut() async {
        signInGeneration += 1
        lastHarvestFailure = nil
        inFlightTokenTask?.task.cancel()
        inFlightTokenTask = nil
        inFlightRefreshTask?.cancel()
        inFlightRefreshTask = nil
        await clearToken()
    }

    private func clearToken() async {
        tokens.drop()
        let purgeHosts: Set<String> = ["ssoam2.ntust.edu.tw", "moodle2.ntust.edu.tw"]
        HTTPCookieStorage.shared.cookies?
            .filter { cookie in
                let cleaned = String(cookie.domain.drop(while: { $0 == "." }))
                if purgeHosts.contains(cleaned) { return true }
                return purgeHosts.contains(where: { $0.hasSuffix("." + cleaned) })
            }
            .forEach { HTTPCookieStorage.shared.deleteCookie($0) }
        await MoodleSiteInfoService.shared.invalidateCache()
    }

    func currentToken() async -> String? {
        tokens.load()
    }

    struct TokenTriple: Sendable {
        let signature: String
        let wstoken: String
        let privatetoken: String?
        var postedPassword = false
    }

    nonisolated static func harvestConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpAdditionalHeaders = [
            "User-Agent": mobileUA,
            "Accept":
                "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-TW,zh;q=0.9,en-US;q=0.8,en;q=0.7",
        ]
        return config
    }

    private nonisolated static func performOidcLogin(
        studentId: String,
        password: String
    ) async throws -> TokenTriple {
        let config = harvestConfiguration()
        let session = URLSession(
            configuration: config,
            delegate: TLSPinningDelegate.shared,
            delegateQueue: nil,
        )
        defer { session.invalidateAndCancel() }

        let passport = Int(Double.random(in: 0..<1) * 1000)
        var launchComps = URLComponents(
            url: AppConstants.moodleBaseURL.appendingPathComponent("admin/tool/mobile/launch.php"),
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
        let (initialData, initialResp) = try await dataTask(
            session: session,
            request: URLRequest(url: launchURL),
        )
        try assertOK(response: initialResp, data: initialData)
        guard let initialURL = (initialResp as? HTTPURLResponse)?.url else {
            throw MoodleWebserviceError.malformedResponse(detail: "missing initial response URL")
    /// The harvest's session. The shared cookie store keeps SSO anti-forgery and correlation
    /// cookies across the launch.php -> login -> authorize redirects; a private jar on Apple's
    /// URLSession stack drops them, and the credential POST bounces to /account/login as a false
    /// rejection. A harvest holds the stored-password lock, so a request whose server trickles its
    /// answer stops after a minute, as `NTUSTSessionManager`'s requests do, rather than the default
    /// week, and the harvest as a whole after ``harvestDeadline``.
        }
        return try await resolveTokenTriple(
            session: session,
            data: initialData,
            responseURL: initialURL,
            studentId: studentId,
            password: password,
            remainingSteps: 6,
        )
    }

    private nonisolated static func dataTask(
        session: URLSession,
        request: URLRequest,
        delegate: (any URLSessionTaskDelegate & Sendable)? = nil,
    ) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request, delegate: delegate)
        } catch let urlError as URLError {
            throw MoodleWebserviceError.transientNetwork(
                underlying: urlError.localizedDescription,
            )
        }
    }

    private nonisolated static func assertOK(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MoodleWebserviceError.transientNetwork(
                underlying: "No HTTP response",
            )
        }
        // Step 1: GET launch.php; URLSession follows the 303s to the SSO login. The passport is
        // an integer, matching how the Moodle Mobile App generates it: `String(Double)` can emit
        // `1e-06` or a locale's `,`, either of which Moodle's `weblogin` may reject.
        if http.statusCode != 200 {
            if let moodleError = MoodleWebserviceError.from(jsonData: data) {
                throw moodleError
            }
            throw MoodleWebserviceError.httpStatus(code: http.statusCode)
        }
    }

    private nonisolated static func urlEncodedForm(_ fields: [String: String]) -> Data? {
        urlEncodedForm(fields.map { ($0.key, $0.value) })
    }

    private nonisolated static func urlEncodedForm(_ fields: [(String, String)]) -> Data? {
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

    private struct SSOLoginFields {
        let action: String
        let antiforgery: String
        let clientId: String
        let returnUrl: String
        let uri: String
    }

    private struct OIDCBridge {
        let action: URL
        let payload: [String: String]
    }

    nonisolated static func resolveTokenTriple(
        session: URLSession,
        data: Data,
        responseURL: URL,
        studentId: String,
        password: String,
        remainingSteps: Int,
    ) async throws -> TokenTriple {
        guard remainingSteps > 0 else {
            throw MoodleWebserviceError.malformedResponse(
                detail: "OIDC flow exceeded maximum step count",
            )
        }

        let html = String(data: data, encoding: .utf8) ?? ""

        if let b64 = extractMoodleMobileToken(from: html) {
            return try decodeTokenTriple(from: b64)
        }

        if let bridge = parseOIDCBridge(from: html) {
            guard CredentialPost.isSchoolTarget(bridge.action) else {
                throw MoodleWebserviceError.malformedResponse(detail: "OIDC bridge posts over plain HTTP")
            }
            var bridgeReq = URLRequest(url: bridge.action)
            bridgeReq.httpMethod = "POST"
            bridgeReq.setValue(
                "application/x-www-form-urlencoded",
                forHTTPHeaderField: "Content-Type",
            )
            bridgeReq.httpBody = urlEncodedForm(bridge.payload)
            let (nextData, nextResp) = try await dataTask(
                session: session, request: bridgeReq, delegate: CredentialPostDelegate()
            )
            try assertOK(response: nextResp, data: nextData)
            guard let nextURL = (nextResp as? HTTPURLResponse)?.url else {
                throw MoodleWebserviceError.malformedResponse(detail: "missing bridge response URL")
            }
            return try await resolveTokenTriple(
                session: session,
                data: nextData,
                responseURL: nextURL,
                studentId: studentId,
                password: password,
                remainingSteps: remainingSteps - 1,
            )
        }

        if responseURL.host == "ssoam2.ntust.edu.tw" {
            let fields = parseSSOLoginFields(from: html)
            if fields.antiforgery.isEmpty {
                throw MoodleWebserviceError.malformedResponse(
                    detail: "SSO login form missing anti-forgery token",
                )
            }

            let postURL = URL(string: fields.action, relativeTo: responseURL)?
                .absoluteURL ?? ssoBaseURL
            guard CredentialPost.isSignInTarget(postURL) else {
                throw MoodleWebserviceError.malformedResponse(
                    detail: "SSO login form posts outside ssoam2",
                )
            }
            var postReq = URLRequest(url: postURL)
            postReq.httpMethod = "POST"
            postReq.setValue(
                "application/x-www-form-urlencoded",
                forHTTPHeaderField: "Content-Type",
            )
            postReq.setValue(responseURL.absoluteString, forHTTPHeaderField: "Referer")
            postReq.setValue(
                ssoBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                forHTTPHeaderField: "Origin",
            )
            postReq.httpBody = urlEncodedForm([
                ("__RequestVerificationToken", fields.antiforgery),
                ("Username", studentId),
                ("Password", password),
                ("captcha", ""),
                ("cf-turnstile-response", ""),
                ("h-captcha-response", ""),
                ("g-recaptcha-response", ""),
                ("ClientId", fields.clientId),
                ("ReturnUrl", fields.returnUrl),
                ("Uri", fields.uri),
            ])
            let (nextData, nextResp) = try await dataTask(
                session: session,
                request: postReq,
                delegate: CredentialPostDelegate(),
            )
            try assertOK(response: nextResp, data: nextData)
            guard let nextURL = (nextResp as? HTTPURLResponse)?.url else {
                throw MoodleWebserviceError.malformedResponse(detail: "missing login response URL")
            }
            let nextHTML = String(data: nextData, encoding: .utf8) ?? ""
            if nextURL.absoluteString.contains("/account/login"),
               extractMoodleMobileToken(from: nextHTML) == nil,
               parseOIDCBridge(from: nextHTML) == nil {
                throw MoodleWebserviceError.ssoLoginRejected(
                    reason: HTMLParser.loginErrorMessage(in: nextHTML),
                )
            }
            var triple = try await resolveTokenTriple(
                session: session,
                data: nextData,
                responseURL: nextURL,
                studentId: studentId,
                password: password,
                remainingSteps: remainingSteps - 1,
            )
            triple.postedPassword = true
            return triple
        }

        throw MoodleWebserviceError.malformedResponse(
            detail: "unexpected OIDC page: \(responseURL.absoluteString)",
        )
    }

    nonisolated static func decodeTokenTriple(from base64Token: String) throws -> TokenTriple {
        var standardized = base64Token
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = standardized.count % 4
        if padding != 0 {
            standardized.append(String(repeating: "=", count: 4 - padding))
        }
        guard let decodedData = Data(base64Encoded: standardized),
              let decoded = String(data: decodedData, encoding: .isoLatin1) else {
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

    private nonisolated static func parseSSOLoginFields(from html: String) -> SSOLoginFields {
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        var action = "/"
        var fields: [String: String] = [:]
        formBlockRegex.enumerateMatches(in: html, options: [], range: range) { match, _, stop in
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

    private nonisolated static func parseOIDCBridge(from html: String) -> OIDCBridge? {
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        var result: OIDCBridge?
        formBlockRegex.enumerateMatches(in: html, options: [], range: range) { match, _, stop in
            guard let m = match, m.numberOfRanges >= 2 else { return }
            let formFull = ns.substring(with: m.range)
            let formBody = ns.substring(with: m.range(at: 1))
            guard let action = extractFormAction(from: formFull) else {
                return
            }
            let payload = extractInputPairs(from: formBody)
            guard let resolvedActionURL = URL(string: action, relativeTo: ssoBaseURL)?.absoluteURL else { return }
            let isOidcAction = resolvedActionURL.host == "moodle2.ntust.edu.tw"
        // `Data(base64Encoded:)` takes only the standard padded alphabet, so map the URL-safe
        // `-` and `_` and pad. The extraction regex allows `-` and `_` since Moodle may emit
        // either encoding.
                && resolvedActionURL.path.hasPrefix("/auth/oidc")
            if isOidcAction,
                payload["code"] != nil
                && payload["state"] != nil
                && payload["iss"] != nil {
                result = OIDCBridge(action: resolvedActionURL, payload: payload)
                stop.pointee = true
            }
        }
        return result
    }

    private nonisolated static func extractFormAction(from formTag: String) -> String? {
        let ns = formTag as NSString
        guard let m = formActionRegex.firstMatch(
            in: formTag,
            options: [],
            range: NSRange(location: 0, length: ns.length),
        ), m.numberOfRanges >= 2 else {
            return nil
        }
        return ns.substring(with: m.range(at: 1))
    }

    private nonisolated static func extractInputNames(from html: String) -> Set<String> {
        let ns = html as NSString
        var names = Set<String>()
        inputNameRegex.enumerateMatches(
            in: html,
            options: [],
            range: NSRange(location: 0, length: ns.length),
        ) { match, _, _ in
            guard let m = match, m.numberOfRanges >= 2 else { return }
            names.insert(ns.substring(with: m.range(at: 1)))
        }
        return names
    }

    private nonisolated static func extractInputPairs(from html: String) -> [String: String] {
        let ns = html as NSString
        var out: [String: String] = [:]
        inputTagRegex.enumerateMatches(
            in: html,
            options: [],
            range: NSRange(location: 0, length: ns.length),
        ) { match, _, _ in
            guard let m = match else { return }
            let tag = ns.substring(with: m.range)
            let tagNs = tag as NSString
            let tagRange = NSRange(location: 0, length: tagNs.length)
            guard let nm = inputNameAttrRegex.firstMatch(in: tag, options: [], range: tagRange),
                  nm.numberOfRanges >= 2 else {
                return
            }
            let name = tagNs.substring(with: nm.range(at: 1))
            let value: String
            if let vm = inputValueAttrRegex.firstMatch(in: tag, options: [], range: tagRange),
               vm.numberOfRanges >= 2 {
                value = tagNs.substring(with: vm.range(at: 1))
            } else {
                value = ""
            }
            out[name] = decodeHTMLEntities(value)
        }
        return out
    }

    private nonisolated static func extractMoodleMobileToken(from html: String) -> String? {
        let ns = html as NSString
        guard let m = moodleMobileTokenRegex.firstMatch(
            in: html,
            options: [],
            range: NSRange(location: 0, length: ns.length),
        ), m.numberOfRanges >= 2 else {
            return nil
        }
        return ns.substring(with: m.range(at: 1))
    }

    private nonisolated static func decodeHTMLEntities(_ s: String) -> String {
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
