import Foundation

/// The library API's sign-in and QR code requests.
enum LibraryRequests {
    private static let baseURL = "https://api.lib.ntust.edu.tw/v1"

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return SchoolSessions.pinned(config)
    }()

    private static func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LibraryServiceError.networkError(URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            let underlying = URLError(
                .badServerResponse,
                userInfo: [
                    NSLocalizedDescriptionKey: "HTTP \(http.statusCode)",
                    "statusCode": http.statusCode,
                ]
            )
            throw LibraryServiceError.networkError(underlying)
        }
    }

    static func requestToken(username: String, password: String, session: URLSession) async throws -> LibraryLoginData {
        do {
            #if DEBUG
            try await ServerFailureSimulator.shared.check(.library)
            #endif
            let url = URL(string: "\(baseURL)/passport/login")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(
                LibraryLoginRequest(username: username, password: password)
            )

            let (data, urlResponse) = try await session.data(for: request, delegate: CredentialPostDelegate())
            return try loginAnswer(urlResponse, data: data)
        } catch {
            AppLogger.captureError(error, context: ["service": "libraryLogin"])
            throw error
        }
    }

    static func loginAnswer(_ response: URLResponse, data: Data) throws -> LibraryLoginData {
        if let status = (response as? HTTPURLResponse)?.statusCode, (400..<500).contains(status) {
            throw LibraryServiceError.loginFailed("HTTP \(status)")
        }
        try validateHTTP(response)
        let decoded = try JSONDecoder().decode(LibraryLoginResponse.self, from: data)
        // Treat missing `error` as success (the API omits it on the
        // happy path); only fail when an explicit non-zero code is set.
        if let apiError = decoded.error, apiError.code != 0 {
            throw LibraryServiceError.loginFailed(apiError.message)
        }
        guard let loginData = decoded.data else {
            throw LibraryServiceError.loginFailed("missing data")
        }
        return loginData
    }

    static func requestQRCode(token: String, session: URLSession) async throws -> String {
        #if DEBUG
        try await ServerFailureSimulator.shared.check(.library)
        #endif
        let url = URL(string: "\(baseURL)/virtual-code/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(LibraryQRRequest(token: token))

        let (data, urlResponse) = try await session.data(for: request, delegate: CredentialPostDelegate())
        try validateHTTP(urlResponse)
        let response = try JSONDecoder().decode(LibraryQRResponse.self, from: data)

        if let apiError = response.error, apiError.code != 0 {
            throw LibraryServiceError.qrGenerationFailed(apiError.message)
        }
        guard let qrData = response.data else { throw LibraryServiceError.qrGenerationFailed("missing data") }
        return qrData
    }
}
