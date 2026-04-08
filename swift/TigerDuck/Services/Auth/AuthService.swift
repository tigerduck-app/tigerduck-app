import Foundation

@Observable
final class AuthService {
    /// Bump to force SwiftUI re-evaluation of computed properties
    /// that read from external stores (Keychain, cookie jar).
    private var _revision = 0

    var isNTUSTAuthenticated: Bool {
        _ = _revision
        return NTUSTSessionManager.shared.cookiesValid && storedStudentId != nil
    }

    var isLoggingIn = false
    var loginError: String?

    var storedStudentId: String? {
        _ = _revision
        return KeychainManager.loadString(key: AppConstants.KeychainKeys.studentId)
    }

    var storedPassword: String? {
        _ = _revision
        return KeychainManager.loadString(key: AppConstants.KeychainKeys.password)
    }

    func login(studentId: String, password: String) async -> Bool {
        isLoggingIn = true
        loginError = nil

        do {
            let session = NTUSTSessionManager.shared.session
            let serviceURL = URL(string: "https://courseselection.ntust.edu.tw/")!
            let normalizedId = studentId.trimmingCharacters(in: .whitespaces).uppercased()

            let success = try await SSOLoginService.ensureServiceLogin(
                session: session,
                serviceURL: serviceURL,
                studentId: normalizedId,
                password: password
            )

            if success {
                KeychainManager.saveString(key: AppConstants.KeychainKeys.studentId, value: normalizedId)
                KeychainManager.saveString(key: AppConstants.KeychainKeys.password, value: password)
                _revision += 1

                // Auto-attempt library login with same credentials (best-effort)
                if !LibraryService.isTokenValid {
                    _ = try? await LibraryService.login(username: normalizedId, password: password)
                }
            }

            isLoggingIn = false
            return success
        } catch {
            loginError = error.localizedDescription
            isLoggingIn = false
            return false
        }
    }

    /// Re-authenticate using stored credentials
    func ensureAuthenticated() async -> Bool {
        guard let studentId = storedStudentId, let password = storedPassword else {
            return false
        }

        if NTUSTSessionManager.shared.cookiesValid {
            return true
        }

        return await login(studentId: studentId, password: password)
    }

    func logout() {
        KeychainManager.delete(key: AppConstants.KeychainKeys.studentId)
        KeychainManager.delete(key: AppConstants.KeychainKeys.password)
        NTUSTSessionManager.shared.invalidateSession()
        loginError = nil
        _revision += 1
    }
}
