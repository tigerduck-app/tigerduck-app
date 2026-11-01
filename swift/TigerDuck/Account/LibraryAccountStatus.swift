import Foundation

/// Whether a library account is stored, for views to observe: `LibraryService` keeps it in the
/// Keychain, which nothing observes, so each change bumps `revision`.
@MainActor
@Observable
final class LibraryAccountStatus {
    private var revision = 0
    @ObservationIgnored private var observer: Any?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: LibraryService.signInDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteChange() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var isLoggedIn: Bool {
        _ = revision
        return LibraryService.hasAccount
    }

    var username: String? {
        _ = revision
        return LibraryService.storedUsername
    }

    func logout() {
        LibraryService.clearCredentials()
        revision += 1
    }

    func noteChange() {
        revision += 1
    }
}

@MainActor
enum LibraryAccount {
    static let didChange = LibraryService.accountDidChange
    static let signInDidChange = LibraryService.signInDidChange

    static var hasAccount: Bool { LibraryService.hasAccount }
    static var username: String? { LibraryService.storedUsername }
    static var isTokenValid: Bool { LibraryService.isTokenValid }
    static var canSignInWithStoredCredentials: Bool { LibraryService.canSignInWithStoredCredentials }

    static var suggestedUsername: String {
        LibraryService.storedUsername ?? KeychainManager.loadString(key: AppConstants.KeychainKeys.studentId) ?? ""
    }

    static func signIn(username: String, password: String) async throws {
        try await LibraryService.login(username: username, password: password)
    }

    static func code() async throws -> String {
        try await LibraryService.generateQRCode()
    }
}
