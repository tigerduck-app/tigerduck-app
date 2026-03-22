import Foundation

@Observable
final class AuthService {
    var isNTUSTAuthenticated: Bool {
        NTUSTSessionManager.shared.cookiesValid && storedStudentId != nil
    }

    var isLoggingIn = false
    var loginError: String?

    var storedStudentId: String? {
        guard let data = KeychainManager.load(key: "ntust_student_id") else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private var storedPassword: String? {
        guard let data = KeychainManager.load(key: "ntust_password") else { return nil }
        return String(data: data, encoding: .utf8)
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
                // Store credentials in Keychain
                if let idData = studentId.uppercased().data(using: .utf8) {
                    KeychainManager.save(key: "ntust_student_id", data: idData)
                }
                if let pwData = password.data(using: .utf8) {
                    KeychainManager.save(key: "ntust_password", data: pwData)
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
        KeychainManager.delete(key: "ntust_student_id")
        KeychainManager.delete(key: "ntust_password")
        NTUSTSessionManager.shared.invalidateSession()
        loginError = nil
    }
}
