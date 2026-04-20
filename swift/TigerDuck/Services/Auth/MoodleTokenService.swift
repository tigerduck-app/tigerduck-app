import Foundation

actor MoodleTokenService {
    static let shared = MoodleTokenService()

    private let siteBaseURL = URL(string: "https://moodle2.ntust.edu.tw")!
    private let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    private let session: URLSession

    private var inFlightTokenTask: Task<String, Error>?
    private var inFlightRefreshTask: Task<String, Error>?

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept": "application/json,text/plain,*/*",
            "Accept-Language": "zh-TW,zh;q=0.9",
        ]
        session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Obtain a new Moodle webservice token using explicit credentials.
    /// Concurrent calls share the same in-flight task.
    func obtainToken(studentId: String, password: String) async throws -> String {
        if let existing = inFlightTokenTask {
            return try await existing.value
        }

        let normalizedId = studentId.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let task = Task<String, Error> { [session, siteBaseURL] in
            try await Self.fetchToken(
                with: session,
                siteBaseURL: siteBaseURL,
                studentId: normalizedId,
                password: password
            )
        }
        inFlightTokenTask = task

        do {
            let token = try await task.value
            inFlightTokenTask = nil
            return token
        } catch {
            inFlightTokenTask = nil
            throw error
        }
    }

    /// Silently refresh the Moodle token using stored NTUST credentials.
    /// Concurrent calls share the same in-flight refresh task.
    func refreshTokenIfNeeded() async throws -> String {
        if let existing = inFlightRefreshTask {
            return try await existing.value
        }

        let credentials = await MainActor.run {
            (
                KeychainManager.loadString(key: AppConstants.KeychainKeys.studentId),
                KeychainManager.loadString(key: AppConstants.KeychainKeys.password)
            )
        }

        guard let studentId = credentials.0,
              let password = credentials.1 else {
            throw MoodleWebserviceError.invalidCredentials
        }

        let normalizedId = studentId.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let task = Task<String, Error> { [session, siteBaseURL] in
            try await Self.fetchToken(
                with: session,
                siteBaseURL: siteBaseURL,
                studentId: normalizedId,
                password: password
            )
        }
        inFlightRefreshTask = task

        do {
            let token = try await task.value
            inFlightRefreshTask = nil
            return token
        } catch {
            inFlightRefreshTask = nil
            throw error
        }
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

    // MARK: - Private

    private static func fetchToken(
        with session: URLSession,
        siteBaseURL: URL,
        studentId: String,
        password: String
    ) async throws -> String {
        guard var components = URLComponents(url: siteBaseURL, resolvingAgainstBaseURL: false) else {
            throw MoodleWebserviceError.malformedResponse(detail: "invalid base URL")
        }
        components.path = "/login/token.php"
        components.query = nil
        components.fragment = nil

        guard let url = components.url else {
            throw MoodleWebserviceError.malformedResponse(detail: "invalid token URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "username", value: studentId),
            URLQueryItem(name: "password", value: password),
            URLQueryItem(name: "service", value: "moodle_mobile_app"),
        ]
        request.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if let urlError = error as? URLError {
                throw MoodleWebserviceError.transientNetwork(underlying: urlError.localizedDescription)
            }
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MoodleWebserviceError.transientNetwork(underlying: "No HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            if let moodleError = MoodleWebserviceError.from(jsonData: data) {
                throw moodleError
            }
            throw MoodleWebserviceError.httpStatus(code: httpResponse.statusCode)
        }

        if let moodleError = MoodleWebserviceError.from(jsonData: data) {
            throw moodleError
        }

        struct TokenResponse: Decodable {
            let token: String
            let privatetoken: String?
        }

        let tokenResponse: TokenResponse
        do {
            tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw MoodleWebserviceError.malformedResponse(detail: "missing token field")
        }

        guard !tokenResponse.token.isEmpty else {
            throw MoodleWebserviceError.malformedResponse(detail: "missing token field")
        }

        await MainActor.run {
            KeychainManager.saveString(key: AppConstants.KeychainKeys.moodleToken, value: tokenResponse.token)
            if let privateToken = tokenResponse.privatetoken, !privateToken.isEmpty {
                KeychainManager.saveString(key: AppConstants.KeychainKeys.moodlePrivateToken, value: privateToken)
            } else {
                KeychainManager.delete(key: AppConstants.KeychainKeys.moodlePrivateToken)
            }
        }

        return tokenResponse.token
    }
}
