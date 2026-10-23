import SwiftUI

@Observable
final class LibraryViewModel {
    var qrCodeImage: UIImage?
    var qrPayload: String?
    private(set) var codeFetchedAt: Date?
    var countdown: Int = 30
    var isLoadingQR = false
    var errorMessage: String?

    var isLoggedIn = false
    var isLoggingIn = false
    private(set) var signedInUsername: String?

    var onLibraryStateChanged: (() -> Void)?

    @ObservationIgnored var fetchCode: @MainActor () async throws -> String = { try await LibraryService.generateQRCode() }

    var libUsername = ""
    var libPassword = ""

    private var refreshTimer: Timer?
    private var countdownTimer: Timer?
    private var hasLoaded = false
    private var isShowing = false

    private var consecutiveErrors = 0
    @ObservationIgnored var backoffSchedule: [TimeInterval] = [60, 120, 300]
    @ObservationIgnored var refreshInterval: TimeInterval = 30

    @ObservationIgnored nonisolated(unsafe) private var accountObserver: (any NSObjectProtocol)?
    @ObservationIgnored nonisolated(unsafe) private var signInObserver: (any NSObjectProtocol)?

    init() {
        // `queue: nil` delivers synchronously on the posting thread, and
        // `LibraryService` posts from the main actor — so the code is off the
        // screen before the sign-out that invalidated it even returns.
        accountObserver = NotificationCenter.default.addObserver(
            forName: LibraryService.accountDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dropCodeForAccountChange() }
        }
        signInObserver = NotificationCenter.default.addObserver(
            forName: LibraryService.signInDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.followSignInElsewhere() }
        }
    }

    func load() {
        guard !hasLoaded else { return }
        hasLoaded = true
        isLoggedIn = LibraryService.hasAccount
        signedInUsername = LibraryService.storedUsername

        libUsername = Self.prefilledUsername
    }

    func onAppear() {
        isShowing = true
        if !isLoggedIn && LibraryService.hasAccount {
            isLoggedIn = true
            startQRRefreshCycle()
            return
        }
        if hasLoaded && isLoggedIn && !LibraryService.isTokenValid {
            qrCodeImage = nil
            qrPayload = nil
            codeFetchedAt = nil
            isLoadingQR = false
            LibraryQRCache.shared.clear()
            LibraryQRImageCache.shared.clear()
            stopTimers()
            if LibraryService.canSignInWithStoredCredentials {
                startQRRefreshCycle()
            } else {
                isLoggedIn = false
                onLibraryStateChanged?()
            }
            return
        }
        if hasLoaded && isLoggedIn && refreshTimer == nil {
            startQRRefreshCycle()
        }
    }

    func onDisappear() {
        isShowing = false
        stopTimers()
        libPassword = ""
    }

    func loginAndStart() {
        let trimmedUsername = libUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty, !libPassword.isEmpty, !isLoggingIn else { return }
        isLoggingIn = true
        Task { @MainActor in
            errorMessage = nil
            do {
                try await LibraryService.login(
                    username: trimmedUsername.uppercased(),
                    password: libPassword
                )
                libPassword = ""
                isLoggedIn = true
                isLoggingIn = false
                signedInUsername = LibraryService.storedUsername
                startQRRefreshCycle()
                onLibraryStateChanged?()
            } catch {
                errorMessage = error.localizedDescription
                libPassword = ""
                isLoggingIn = false
            }
        }
    }

    private func fetchAndDisplayQR() {
        Task { @MainActor in
            isLoadingQR = qrCodeImage == nil
            errorMessage = nil
            let generation = LibraryService.loginGeneration
            do {
                let payload = try await fetchCode()
                let image = await Task.detached(priority: .userInitiated) {
                    LibraryQRRenderer.image(from: payload)
                }.value
                guard LibraryService.loginGeneration == generation else { return }
                LibraryQRCache.shared.store(payload)
                if let image { LibraryQRImageCache.shared.store(image, for: payload) }
                qrPayload = payload
                codeFetchedAt = LibraryQRCache.shared.fetchedAt
                qrCodeImage = image
                isLoadingQR = false
                consecutiveErrors = 0
                restartCountdown()
            } catch {
                guard LibraryService.loginGeneration == generation else { return }
                errorMessage = error.localizedDescription
                isLoadingQR = false
                if !LibraryService.hasAccount {
                    showSignInForm()
                } else {
                    consecutiveErrors += 1
                    rescheduleAfterError()
                }
            }
        }
    }

    private func showSignInForm() {
        isLoggedIn = false
        consecutiveErrors = 0
        codeFetchedAt = nil
        LibraryQRCache.shared.clear()
        LibraryQRImageCache.shared.clear()
        stopTimers()
        onLibraryStateChanged?()
    }

    private func followSignInElsewhere() {
        if isLoggedIn, !LibraryService.hasAccount {
            errorMessage = nil
            showSignInForm()
        } else if hasLoaded, !isLoggedIn, !isLoggingIn, LibraryService.hasAccount {
            isLoggedIn = true
            signedInUsername = LibraryService.storedUsername
            errorMessage = nil
            libPassword = ""
            onLibraryStateChanged?()
            if isShowing { startQRRefreshCycle() }
        }
    }

    private func rescheduleAfterError() {
        let idx = min(consecutiveErrors - 1, backoffSchedule.count - 1)
        let interval = backoffSchedule[max(0, idx)]
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.startQRRefreshCycle()
        }
    }

    private func startQRRefreshCycle() {
        refreshTimer?.invalidate()
        let cache = LibraryQRCache.shared
        if let payload = cache.reusable() {
            let remaining = cache.remaining()
            codeFetchedAt = cache.fetchedAt
            if qrPayload != payload || qrCodeImage == nil {
                qrPayload = payload
                if let memoized = LibraryQRImageCache.shared.image(for: payload) {
                    qrCodeImage = memoized
                    isLoadingQR = false
                } else {
                    isLoadingQR = qrCodeImage == nil
                    let generation = LibraryService.loginGeneration
                    Task { @MainActor in
                        let image = await Task.detached(priority: .userInitiated) {
                            LibraryQRRenderer.image(from: payload)
                        }.value
                        guard qrPayload == payload else { return }
                        guard LibraryService.loginGeneration == generation else { return }
                        if let image { LibraryQRImageCache.shared.store(image, for: payload) }
                        qrCodeImage = image
                        isLoadingQR = false
                    }
                }
            }
            restartCountdown(from: remaining)
            refreshTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(remaining), repeats: false) { [weak self] _ in
                self?.startQRRefreshCycle()
            }
            return
        }

        fetchAndDisplayQR()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.fetchAndDisplayQR()
        }
    }

    private func restartCountdown(from seconds: Int = LibraryQRCache.lifetime) {
        countdown = seconds
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if self.countdown > 0 {
                    self.countdown -= 1
                }
            }
        }
    }

    private func dropCodeForAccountChange() {
        stopTimers()
        qrCodeImage = nil
        qrPayload = nil
        codeFetchedAt = nil
        isLoadingQR = false
        consecutiveErrors = 0
        isLoggedIn = LibraryService.hasAccount
        signedInUsername = LibraryService.storedUsername
        libUsername = Self.prefilledUsername
        libPassword = ""
    }

    private static var prefilledUsername: String {
        LibraryService.storedUsername
            ?? KeychainManager.loadString(key: AppConstants.KeychainKeys.studentId)
            ?? ""
    }

    func stopTimers() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    deinit {
        stopTimers()
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
        if let signInObserver { NotificationCenter.default.removeObserver(signInObserver) }
    }
}
