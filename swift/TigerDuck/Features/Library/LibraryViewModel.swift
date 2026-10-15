import SwiftUI

@Observable
final class LibraryViewModel {
    var qrCodeImage: UIImage?
    var qrPayload: String?
    /// When the code on screen was issued, for the status dot's last sync; nil with no code.
    private(set) var codeFetchedAt: Date?
    var countdown: Int = 30
    var isLoadingQR = false
    var errorMessage: String?

    var isLoggedIn = false
    var isLoggingIn = false
    /// The signed-in library account the pass names, read once rather than from the keychain on
    /// every second's redraw.
    private(set) var signedInUsername: String?

    /// Invoked whenever this screen changes the stored library credential state: a sign-in,
    /// or a token found expired.
    ///
    /// `AppState.isLibraryLoggedIn` reads the keychain behind an observable revision counter, so a
    /// change that does not bump it leaves every other screen, Settings included, showing the
    /// previous answer. A closure rather than an `AppState` parameter, because the QR refresh that
    /// finds a dead token runs off a timer and has no view to hand one in.
    var onLibraryStateChanged: (() -> Void)?

    /// The code request, replaced in tests so nothing leaves the process.
    @ObservationIgnored var fetchCode: @MainActor () async throws -> String = { try await LibraryService.generateQRCode() }

    // Manual login fields
    var libUsername = ""
    var libPassword = ""

    private var refreshTimer: Timer?
    private var countdownTimer: Timer?
    private var hasLoaded = false

    /// Number of consecutive transient failures since the last
    /// successful refresh. Drives the backoff schedule below — a flapping
    /// 5xx loop hammered the library API every 30s with no breathing
    /// room, so the next refresh is delayed proportionally.
    private var consecutiveErrors = 0
    /// Backoff cadence after N transient failures (seconds). After the
    /// final entry the cadence holds at the last value until a refresh
    /// succeeds. Tests shorten it and the refresh interval.
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
            MainActor.assumeIsolated { self?.signOutIfRefusedElsewhere() }
        }
    }

    // MARK: - Lifecycle

    func load() {
        guard !hasLoaded else { return }
        hasLoaded = true
        // Stored credentials count: the code's fetch signs in again with them.
        isLoggedIn = LibraryService.hasAccount
        signedInUsername = LibraryService.storedUsername

        libUsername = Self.prefilledUsername
    }

    func onAppear() {
        // Re-check in case user logged in via Settings, or the stored credentials can sign in
        // again after a failed attempt (a sign-in at the return to the app may be under way).
        if !isLoggedIn && LibraryService.hasAccount {
            isLoggedIn = true
            startQRRefreshCycle()
            return
        }
        // If the token expired while backgrounded (the user back after more than 24 h), drop the
        // stale-token QR at once rather than showing it for up to 30 s. Stored credentials sign
        // in again behind a fresh code; without them the page shows the sign-in form.
        if hasLoaded && isLoggedIn && !LibraryService.isTokenValid {
            qrCodeImage = nil
            qrPayload = nil
            codeFetchedAt = nil
            // A request still in flight from the ended session is dropped
            // without touching this flag, so nothing else will clear it.
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
        stopTimers()
        // Defense-in-depth: drop the in-memory password buffer on view
        // teardown too, in case the user navigates away mid-typing.
        libPassword = ""
    }

    // MARK: - Login

    func loginAndStart() {
        // Keyboard Return key bypasses the login button's `.disabled(...)` —
        // reject empty credentials here so a stray Submit doesn't hit the
        // NTUST endpoint with blank fields.
        let trimmedUsername = libUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty, !libPassword.isEmpty, !isLoggingIn else { return }
        // Set synchronously, before the Task is scheduled, so a second submit on the same runloop
        // turn (Return plus a button tap) sees `isLoggingIn = true` and bails. Otherwise both calls
        // pass the guard before the first Task body runs.
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
                // Clear the password on every failure so it never lingers
                // in @Observable state where a screenshot or screen recording
                // could capture it after a recoverable error.
                libPassword = ""
                isLoggingIn = false
            }
        }
    }

    // MARK: - QR Code

    private func fetchAndDisplayQR() {
        Task { @MainActor in
            isLoadingQR = qrCodeImage == nil
            errorMessage = nil
            let generation = LibraryService.loginGeneration
            do {
                let payload = try await fetchCode()
                // Rasterise off the main actor: a cold CIContext plus the
                // CGImage render was a visible hitch on older phones.
                let image = await Task.detached(priority: .userInitiated) {
                    LibraryQRRenderer.image(from: payload)
                }.value
                // Sign-out or account switch mid-request: this code is the old session's. Keep it
                // off the shared caches and the screen, and leave `isLoadingQR` to the current
                // request. Returning is enough: the next onAppear or refresh tick shows logged-out.
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
                // As on the success path: a failure from an ended session must not show its error,
                // back off the new session's refresh, clear the caches it now owns, or touch its
                // loading state.
                guard LibraryService.loginGeneration == generation else { return }
                errorMessage = error.localizedDescription
                isLoadingQR = false
                // A lapsed token whose stored credentials did not answer, as on a weak signal at the
                // gate, backs off and tries again; only a signed-out account gets the sign-in form.
                if !LibraryService.hasAccount {
                    showSignInForm()
                } else {
                    // Transient (5xx etc.) — back off so a flapping
                    // server can't keep the 30s timer hammering it.
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

    /// A refusal of the stored password found by another caller, such as the sign-in at launch or
    /// the Watch's, signs the account out everywhere else at once. A page backing off after a failed
    /// request would show itself signed in, with that request's error, until its retry.
    private func signOutIfRefusedElsewhere() {
        guard isLoggedIn, !LibraryService.hasAccount else { return }
        errorMessage = nil
        showSignInForm()
    }

    /// Restart the refresh timer with the current backoff interval. Holds
    /// at the last value of `backoffSchedule` for additional failures so
    /// retries never exceed 5 minutes.
    private func rescheduleAfterError() {
        let idx = min(consecutiveErrors - 1, backoffSchedule.count - 1)
        let interval = backoffSchedule[max(0, idx)]
        refreshTimer?.invalidate()
        // The retry starts the cycle again, so a retry that works goes back to a fresh code every
        // interval instead of leaving the one it fetched to run out on screen.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.startQRRefreshCycle()
        }
    }

    // MARK: - Timers

    /// Coming back to the page while the last code still has at least
    /// `LibraryQRCache.reuseThreshold` seconds left shows that same code
    /// and resumes its countdown; the next fetch is scheduled for when it
    /// runs out. Otherwise fetch now and every 30 s after.
    private func startQRRefreshCycle() {
        refreshTimer?.invalidate()
        let cache = LibraryQRCache.shared
        if let payload = cache.reusable() {
            let remaining = cache.remaining()
            codeFetchedAt = cache.fetchedAt
            if qrPayload != payload || qrCodeImage == nil {
                qrPayload = payload
                // A payload rendered on an earlier visit is assigned synchronously, so the QR is on
                // screen in the first frame instead of after a hop through a detached render.
                if let memoized = LibraryQRImageCache.shared.image(for: payload) {
                    qrCodeImage = memoized
                    isLoadingQR = false
                } else {
                    // No memo, so a render is ahead. An empty card shows the spinner: its inert
                    // `qrcode` glyph would read as "no code" while the countdown runs. A card that
                    // shows a code keeps it until the new one lands, as `fetchAndDisplayQR` does.
                    isLoadingQR = qrCodeImage == nil
                    let generation = LibraryService.loginGeneration
                    Task { @MainActor in
                        let image = await Task.detached(priority: .userInitiated) {
                            LibraryQRRenderer.image(from: payload)
                        }.value
                        // The 30 s refresh can rotate the payload mid-render. A late render must
                        // not show an expired matrix under the new code's countdown, nor be stored:
                        // the single-slot cache would evict the current entry and miss next visit.
                        guard qrPayload == payload else { return }
                        // Same reasoning as `fetchAndDisplayQR`: a logout in
                        // this window already cleared both caches, and these
                        // pixels must not refill them.
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

    /// The library account changed underneath this screen — signed out in
    /// Settings, or someone else signed in. The code on screen is the
    /// previous account's and still scans, so it goes now rather than at the
    /// next refresh tick or the next `onAppear`. Nothing is fetched from here:
    /// a sign-in on this screen starts its own cycle, and one made elsewhere
    /// is picked up by `onAppear`.
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

    /// The sign-in form's student ID: the stored library account's, else the school account's.
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
