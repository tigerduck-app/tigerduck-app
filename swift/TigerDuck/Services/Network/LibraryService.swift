import Foundation

enum LibraryServiceError: LocalizedError {
    case credentialsNotFound
    case loginFailed(String)
    case qrGenerationFailed(String)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .credentialsNotFound: "找不到圖書館帳號密碼"
        case .loginFailed(let msg): "圖書館登入失敗：\(msg)"
        case .qrGenerationFailed(let msg): "QR 碼產生失敗：\(msg)"
        case .networkError(let e): "網路錯誤：\(e.localizedDescription)"
        }
    }
}

enum LibraryService {
    private static let baseURL = "https://api.lib.ntust.edu.tw/v1"

    // MARK: - Credential Management

    static var storedUsername: String? {
        KeychainManager.loadString(key: AppConstants.KeychainKeys.libraryUsername)
    }

    static func saveCredentials(username: String, password: String) {
        KeychainManager.saveString(key: AppConstants.KeychainKeys.libraryUsername, value: username)
        KeychainManager.saveString(key: AppConstants.KeychainKeys.libraryPassword, value: password)
    }

    static func clearCredentials() {
        KeychainManager.delete(key: AppConstants.KeychainKeys.libraryUsername)
        KeychainManager.delete(key: AppConstants.KeychainKeys.libraryPassword)
        clearToken()
    }

    private static var storedPassword: String? {
        KeychainManager.loadString(key: AppConstants.KeychainKeys.libraryPassword)
    }

    // MARK: - Token Management

    static var storedToken: String? {
        KeychainManager.loadString(key: AppConstants.KeychainKeys.libraryToken)
    }

    static var storedTokenExpiry: Date? {
        guard let str = KeychainManager.loadString(key: AppConstants.KeychainKeys.libraryTokenExpiry),
              let ms = Int64(str) else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000.0)
    }

    static var isTokenValid: Bool {
        guard storedToken != nil, let expiry = storedTokenExpiry else { return false }
        return Date() < expiry
    }

    private static func saveToken(_ token: String, expirationMs: Int64) {
        KeychainManager.saveString(key: AppConstants.KeychainKeys.libraryToken, value: token)
        KeychainManager.saveString(key: AppConstants.KeychainKeys.libraryTokenExpiry, value: String(expirationMs))
    }

    static func clearToken() {
        KeychainManager.delete(key: AppConstants.KeychainKeys.libraryToken)
        KeychainManager.delete(key: AppConstants.KeychainKeys.libraryTokenExpiry)
    }

    // MARK: - API Calls

    /// Login with explicit credentials and save them on success.
    @discardableResult
    static func login(username: String, password: String) async throws -> String {
        let url = URL(string: "\(baseURL)/passport/login")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            LibraryLoginRequest(username: username, password: password)
        )

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(LibraryLoginResponse.self, from: data)

        guard response.error.code == 0, let loginData = response.data else {
            throw LibraryServiceError.loginFailed(response.error.message)
        }

        saveCredentials(username: username, password: password)
        saveToken(loginData.token, expirationMs: loginData.expirationTimeStamp)
        return loginData.token
    }

    /// Returns a valid token, re-logging in with stored library credentials if expired.
    static func ensureToken() async throws -> String {
        if let token = storedToken, isTokenValid {
            return token
        }

        guard let username = storedUsername,
              let password = storedPassword else {
            throw LibraryServiceError.credentialsNotFound
        }

        return try await login(username: username, password: password)
    }

    /// Generates a QR code payload string. Auto-ensures a valid token first.
    static func generateQRCode() async throws -> String {
        let token = try await ensureToken()

        let url = URL(string: "\(baseURL)/virtual-code/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            LibraryQRRequest(token: token)
        )

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(LibraryQRResponse.self, from: data)

        guard response.error.code == 0, let qrData = response.data else {
            throw LibraryServiceError.qrGenerationFailed(response.error.message)
        }

        return qrData
    }
}
