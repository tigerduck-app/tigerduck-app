import Foundation

nonisolated enum MoodleTokenHarvest {
    static let ssoBaseURL = URL(string: "https://ssoam2.ntust.edu.tw")!
    private static let service = "moodle_mobile_app"
    private static let urlScheme = "moodlemobile"
    private static let mobileUA = (
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 "
        + "MoodleMobile 5.1.1 (51100)"
    )

    /// The shared cookie store keeps SSO anti-forgery and correlation cookies across the
    /// launch.php -> login -> authorize redirects; a private jar on Apple's URLSession stack drops
    /// them, and the credential POST bounces to /account/login as a false rejection.
    static func harvestConfiguration() -> URLSessionConfiguration {
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

    static func performOidcLogin(
        studentId: String,
        password: String
    ) async throws -> MoodleTokenService.TokenTriple {
        let config = harvestConfiguration()
        let session = SchoolSessions.pinned(config)
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

    private static func dataTask(
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
        urlEncodedForm(fields.map { ($0.key, $0.value) })
    }

    private static func urlEncodedForm(_ fields: [(String, String)]) -> Data? {
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

    static func resolveTokenTriple(
        session: URLSession,
        data: Data,
        responseURL: URL,
        studentId: String,
        password: String,
        remainingSteps: Int,
    ) async throws -> MoodleTokenService.TokenTriple {
        guard remainingSteps > 0 else {
            throw MoodleWebserviceError.malformedResponse(
                detail: "OIDC flow exceeded maximum step count",
            )
        }

        let html = String(data: data, encoding: .utf8) ?? ""

        if let b64 = MoodleSSOPage.extractMoodleMobileToken(from: html) {
            return try MoodleTokenService.decodeTokenTriple(from: b64)
        }

        if let bridge = MoodleSSOPage.parseOIDCBridge(from: html) {
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
            let fields = MoodleSSOPage.parseSSOLoginFields(from: html)
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
               MoodleSSOPage.extractMoodleMobileToken(from: nextHTML) == nil,
               MoodleSSOPage.parseOIDCBridge(from: nextHTML) == nil {
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
}
