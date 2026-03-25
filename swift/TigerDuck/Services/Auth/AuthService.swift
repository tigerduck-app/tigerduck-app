import Foundation

@Observable
final class AuthService {
    var isNTUSTAuthenticated: Bool {
        NTUSTSessionManager.shared.cookiesValid && storedStudentId != nil
    }

    var isLoggingIn = false
    var loginError: String?

    var storedStudentId: String? {
        KeychainManager.loadString(key: AppConstants.KeychainKeys.studentId)
    }

    var storedPassword: String? {
        KeychainManager.loadString(key: AppConstants.KeychainKeys.password)
    }

    func login(studentId: String, password: String) async -> Bool {
        isLoggingIn = true
        loginError = nil

        do {
            let session = NTUSTSessionManager.shared.session
            let serviceURL = URL(string: "https://courseselection.ntust.edu.tw/")!

            let success = try await SSOLoginService.ensureServiceLogin(
                session: session,
                serviceURL: serviceURL,
                studentId: studentId.trimmingCharacters(in: .whitespaces).uppercased(),
                password: password
            )

            if success {
                let normalizedId = studentId.trimmingCharacters(in: .whitespaces).uppercased()
                KeychainManager.saveString(key: AppConstants.KeychainKeys.studentId, value: normalizedId)
                KeychainManager.saveString(key: AppConstants.KeychainKeys.password, value: password)

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
    }
}
