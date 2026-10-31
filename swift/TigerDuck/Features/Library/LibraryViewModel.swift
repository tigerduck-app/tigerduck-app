import SwiftUI

/// Where the library page's sign-in stands.
enum LibraryAccess: Equatable {
    case signedOut
    case signingIn
    case signedIn(username: String?)

    static var stored: LibraryAccess {
        LibraryAccount.hasAccount ? .signedIn(username: LibraryAccount.username) : .signedOut
    }
}

@Observable
final class LibraryViewModel {
    /// The code on the page: its image and the text it encodes, when the school issued it, and
    /// whether a request for a new one runs while none shows.
    private struct ShownCode {
        var image: UIImage?
        var payload: String?
        var fetchedAt: Date?
        var isLoading = false
    }

    private(set) var access = LibraryAccess.signedOut
    private var code = ShownCode()
    var errorMessage: String?
    var libUsername = ""
    var libPassword = ""
    var onLibraryStateChanged: (() -> Void)?

    @ObservationIgnored let cycle = LibraryCodeCycle()
    private var hasLoaded = false
    private var isShowing = false
    @ObservationIgnored nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []

    var isLoggedIn: Bool { if case .signedIn = access { true } else { false } }

    var isLoggingIn: Bool { access == .signingIn }

    var signedInUsername: String? { if case .signedIn(let username) = access { username } else { nil } }

    var qrCodeImage: UIImage? { get { code.image } set { code.image = newValue } }
    var qrPayload: String? { get { code.payload } set { code.payload = newValue } }
    var codeFetchedAt: Date? { code.fetchedAt }
    var isLoadingQR: Bool { get { code.isLoading } set { code.isLoading = newValue } }
    var countdown: Int { get { cycle.countdown } set { cycle.countdown = newValue } }
    var fetchCode: @MainActor () async throws -> String { get { cycle.fetchCode } set { cycle.fetchCode = newValue } }
    var backoffSchedule: [TimeInterval] { get { cycle.backoffSchedule } set { cycle.backoffSchedule = newValue } }
    var refreshInterval: TimeInterval { get { cycle.refreshInterval } set { cycle.refreshInterval = newValue } }

    /// The wait after a failed code request, which the page lets the user cut short.
    var isWaitingToRetry: Bool { isLoggedIn && errorMessage != nil }

    init() {
        // `queue: nil` delivers synchronously on the posting thread, and
        // `LibraryService` posts from the main actor — so the code is off the
        // screen before the sign-out that invalidated it even returns.
        observers = [
            NotificationCenter.default.addObserver(forName: LibraryAccount.didChange, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.dropCodeForAccountChange() }
            },
            NotificationCenter.default.addObserver(forName: LibraryAccount.signInDidChange, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.followSignInElsewhere() }
            },
        ]
    }

    func load() {
        guard !hasLoaded else { return }
        hasLoaded = true
        access = .stored
        libUsername = LibraryAccount.suggestedUsername
    }

    func onAppear() {
        isShowing = true
        if !isLoggedIn && LibraryAccount.hasAccount {
            access = .signedIn(username: LibraryAccount.username)
            startQRRefreshCycle()
            return
        }
        if hasLoaded && isLoggedIn && !LibraryAccount.isTokenValid {
            code = ShownCode()
            LibraryQRCache.shared.clear()
            LibraryQRImageCache.shared.clear()
            stopTimers()
            if LibraryAccount.canSignInWithStoredCredentials {
                startQRRefreshCycle()
            } else {
                access = .signedOut
                onLibraryStateChanged?()
            }
            return
        }
        if hasLoaded && isLoggedIn && !cycle.isScheduled {
            startQRRefreshCycle()
        }
    }

    func onDisappear() {
        isShowing = false
        stopTimers()
        libPassword = ""
    }

    func retryNow() {
        guard isWaitingToRetry else { return }
        errorMessage = nil
        startQRRefreshCycle()
    }

    func loginAndStart(signIn: (@MainActor @Sendable (String, String) async throws -> Void)? = nil) {
        let trimmedUsername = libUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty, !libPassword.isEmpty, !isLoggingIn else { return }
        access = .signingIn
        let signIn = signIn ?? { try await LibraryAccount.signIn(username: $0, password: $1) }
        Task { @MainActor in
            errorMessage = nil
            do {
                try await signIn(trimmedUsername.uppercased(), libPassword)
                libPassword = ""
                access = .signedIn(username: LibraryAccount.username)
                startQRRefreshCycle()
                onLibraryStateChanged?()
            } catch {
                errorMessage = error.localizedDescription
                libPassword = ""
                if access == .signingIn { access = .signedOut }
            }
        }
    }

    private func fetchAndDisplayQR() {
        Task { @MainActor in
            runShownCodesClock()
            code.isLoading = code.image == nil
            errorMessage = nil
            let isCurrent = AccountSession.library.currentCheck()
            do {
                let payload = try await cycle.fetchCode()
                let image = await Self.render(payload)
                guard isCurrent() else { return }
                LibraryQRCache.shared.store(payload)
                if let image { LibraryQRImageCache.shared.store(image, for: payload) }
                code = ShownCode(image: image, payload: payload, fetchedAt: LibraryQRCache.shared.fetchedAt)
                cycle.noteSuccess()
                restartCountdown()
            } catch {
                guard isCurrent() else { return }
                errorMessage = error.localizedDescription
                code.isLoading = false
                if !LibraryAccount.hasAccount {
                    showSignInForm()
                } else {
                    let pause = cycle.noteFailure()
                    cycle.schedule(after: pause) { [weak self] in self?.startQRRefreshCycle() }
                }
            }
        }
    }

    private func showSignInForm() {
        access = .signedOut
        cycle.noteSuccess()
        code.fetchedAt = nil
        LibraryQRCache.shared.clear()
        LibraryQRImageCache.shared.clear()
        stopTimers()
        onLibraryStateChanged?()
    }

    private func followSignInElsewhere() {
        if isLoggedIn, !LibraryAccount.hasAccount {
            errorMessage = nil
            showSignInForm()
        } else if hasLoaded, !isLoggedIn, !isLoggingIn, LibraryAccount.hasAccount {
            access = .signedIn(username: LibraryAccount.username)
            errorMessage = nil
            libPassword = ""
            onLibraryStateChanged?()
            if isShowing { startQRRefreshCycle() }
        }
    }

    private func startQRRefreshCycle() {
        cycle.cancelSchedule()
        let cache = LibraryQRCache.shared
        guard let payload = cache.reusable() else {
            fetchAndDisplayQR()
            cycle.schedule(after: cycle.refreshInterval, repeats: true) { [weak self] in self?.fetchAndDisplayQR() }
            return
        }
        let remaining = cache.remaining()
        code.fetchedAt = cache.fetchedAt
        if code.payload != payload || code.image == nil {
            code.payload = payload
            if let memoized = LibraryQRImageCache.shared.image(for: payload) {
                code.image = memoized
                code.isLoading = false
            } else {
                code.isLoading = code.image == nil
                let isCurrent = AccountSession.library.currentCheck()
                Task { @MainActor in
                    let image = await Self.render(payload)
                    guard code.payload == payload, isCurrent() else { return }
                    if let image { LibraryQRImageCache.shared.store(image, for: payload) }
                    code.image = image
                    code.isLoading = false
                }
            }
        }
        restartCountdown(from: remaining)
        cycle.schedule(after: TimeInterval(remaining)) { [weak self] in self?.startQRRefreshCycle() }
    }

    private func restartCountdown(from seconds: Int = LibraryQRCache.lifetime) {
        cycle.restartCountdown(from: seconds) { [weak self] in self?.dropExpiredCode() }
    }

    /// A request runs the clock from when the shown code was issued, as reopening the page keeps
    /// that code's expiry.
    private func runShownCodesClock() {
        let age = code.fetchedAt.map { Int(Date().timeIntervalSince($0)) } ?? .max
        if age > LibraryQRCache.lifetime {
            dropExpiredCode()
        } else {
            restartCountdown(from: LibraryQRCache.lifetime - age)
        }
    }

    /// A code past its time no longer scans, so it leaves the page while a request is slow or failed.
    private func dropExpiredCode() {
        cycle.stopCountdown()
        code.image = nil
        code.payload = nil
    }

    private func dropCodeForAccountChange() {
        stopTimers()
        code = ShownCode()
        cycle.noteSuccess()
        // A typed sign-in in flight settles the state when it ends; a second one must not start before.
        if access != .signingIn { access = .stored }
        libUsername = LibraryAccount.suggestedUsername
        libPassword = ""
    }

    private nonisolated static func render(_ payload: String) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { LibraryQRRenderer.image(from: payload) }.value
    }

    func stopTimers() {
        cycle.stop()
    }

    deinit {
        cycle.stop()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
