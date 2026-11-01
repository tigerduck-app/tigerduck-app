import Foundation

@MainActor
@Observable
final class LibraryAccountStatus {
    private var revision = KeychainRevision()
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
        revision.read { LibraryService.hasAccount }
    }

    var username: String? {
        revision.read { LibraryService.storedUsername }
    }

    func logout() {
        LibraryService.clearCredentials()
        revision.moveOn()
    }

    func noteChange() {
        revision.moveOn()
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
