import Foundation

@Observable
final class AuthService {
    var isNTUSTAuthenticated = false
    var isMoodleLinked = false
    var isLibraryAuthenticated = false

    func loginNTUST() async {
        // TODO: Phase 3 — ASWebAuthenticationSession SSO flow
    }

    func logoutNTUST() {
        isNTUSTAuthenticated = false
        isMoodleLinked = false
        KeychainManager.delete(key: "ntust_token")
    }

    func loginLibrary(username: String, password: String) async {
        // TODO: Phase 3 — Library login API
    }

    func logoutLibrary() {
        isLibraryAuthenticated = false
        KeychainManager.delete(key: "library_token")
    }
}
