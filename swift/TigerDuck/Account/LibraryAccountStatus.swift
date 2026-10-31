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
