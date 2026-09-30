import SwiftUI

@Observable
final class LibraryViewModel {
    var qrCodeImage: UIImage?
    var qrPayload: String?
    var countdown: Int = 30
    var isLoadingQR = false
    var errorMessage: String?

    var isLoggedIn = false
    var isLoggingIn = false

    /// Invoked whenever this screen changes the *stored* library credential
    /// state — a sign-in, or a token found expired.
    ///
    /// `AppState.isLibraryLoggedIn` reads the keychain behind an observable
    /// revision counter, so a screen that changes the credential without
    /// bumping that counter leaves every other screen rendering the previous
    /// answer. Settings' own sign-in sheet already bumps it; this screen did
    /// not, so signing in here and switching back to Settings still showed a
    /// red dot and "not signed in" until something unrelated invalidated it.
    ///
    /// A stored closure rather than an `AppState` parameter because two of the
    /// three call sites are timer-driven — the QR refresh discovering a dead
    /// token has no view in the loop to hand one in.
    var onLibraryStateChanged: (() -> Void)?

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
    /// succeeds.
    private static let backoffSchedule: [TimeInterval] = [60, 120, 300]

    @ObservationIgnored nonisolated(unsafe) private var accountObserver: (any NSObjectProtocol)?

    init() {
        // `queue: nil` delivers synchronously on the posting thread, and
        // `LibraryService` posts from the main actor — so the code is off the
        // screen before the sign-out that invalidated it even returns.
        accountObserver = NotificationCenter.default.addObserver(
            forName: LibraryService.accountDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dropCodeForAccountChange() }
        }
    }

    // MARK: - Lifecycle

    func load() {
        guard !hasLoaded else { return }
        hasLoaded = true
        isLoggedIn = LibraryService.isTokenValid

        // Pre-fill username from stored library credentials or NTUST student ID
        if let stored = LibraryService.storedUsername {
            libUsername = stored
        } else if let ntustId = KeychainManager.loadString(key: AppConstants.KeychainKeys.studentId) {
            libUsername = ntustId
        }

        if isLoggedIn {
            startQRRefreshCycle()
        }
    }

    func onAppear() {
        // Re-check in case user logged in via Settings
        if !isLoggedIn && LibraryService.isTokenValid {
            isLoggedIn = true
            startQRRefreshCycle()
            return
        }
        // If the token expired while the app was backgrounded (e.g. user
        // returned after >24h), surface logged-out state up front so the
        // user does not see a stale-token QR for up to 30 s before the
        // next refresh tick collapses to logged-out.
        if hasLoaded && isLoggedIn && !LibraryService.isTokenValid {
            isLoggedIn = false
            qrCodeImage = nil
            qrPayload = nil
            // A request still in flight from the ended session is dropped
            // without touching this flag, so nothing else will clear it.
            isLoadingQR = false
            LibraryQRCache.shared.clear()
            LibraryQRImageCache.shared.clear()
            stopTimers()
            onLibraryStateChanged?()
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
        // Flip the flag synchronously, before the Task is scheduled, so a
        // second submit (e.g. Return + button tap landing on the same
        // runloop turn) sees `isLoggingIn = true` and bails — otherwise
        // both calls clear the guard before the first Task body runs.
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
                let payload = try await LibraryService.generateQRCode()
                // Rasterise off the main actor: a cold CIContext plus the
                // CGImage render was a visible hitch on older phones.
                let image = await Task.detached(priority: .userInitiated) {
                    LibraryQRRenderer.image(from: payload)
                }.value
                // The user signed out — or signed in as someone else — while
                // the request was in flight. This code belongs to whoever was
                // signed in when it was asked for, so it must not reach the
                // process-wide caches or the screen. Dropping it is enough:
                // the next `onAppear` (or the refresh tick, whichever comes
                // first) is what collapses the page to its logged-out state.
                // `isLoadingQR` is left alone too: it belongs to whichever
                // request is current, and a new session's may still be running.
                guard LibraryService.loginGeneration == generation else { return }
                LibraryQRCache.shared.store(payload)
                if let image { LibraryQRImageCache.shared.store(image, for: payload) }
                qrPayload = payload
                qrCodeImage = image
                isLoadingQR = false
                consecutiveErrors = 0
                restartCountdown()
            } catch {
                // Same rule as the success path: a failure from a session
                // that has since ended must not show its error, back off the
                // new session's refresh, clear the caches it now owns, or
                // touch its loading state.
                guard LibraryService.loginGeneration == generation else { return }
                errorMessage = error.localizedDescription
                isLoadingQR = false
                if !LibraryService.isTokenValid {
                    isLoggedIn = false
                    consecutiveErrors = 0
                    LibraryQRCache.shared.clear()
                    LibraryQRImageCache.shared.clear()
                    stopTimers()
                    onLibraryStateChanged?()
                } else {
                    // Transient (5xx etc.) — back off so a flapping
                    // server can't keep the 30s timer hammering it.
                    consecutiveErrors += 1
                    rescheduleAfterError()
                }
            }
        }
    }

    /// Restart the refresh timer with the current backoff interval. Holds
    /// at the last value of `backoffSchedule` for additional failures so
    /// retries never exceed 5 minutes.
    private func rescheduleAfterError() {
        let idx = min(consecutiveErrors - 1, Self.backoffSchedule.count - 1)
        let interval = Self.backoffSchedule[max(0, idx)]
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.fetchAndDisplayQR()
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
            if qrPayload != payload || qrCodeImage == nil {
                qrPayload = payload
                // Already rendered this payload on an earlier visit to the
                // page. Assign synchronously so the QR is on screen in the
                // first frame instead of after a hop through a detached
                // render.
                if let memoized = LibraryQRImageCache.shared.image(for: payload) {
                    qrCodeImage = memoized
                    isLoadingQR = false
                } else {
                    // No memo: there is a render ahead of us, so say so.
                    // Without this the card falls back to the inert
                    // `qrcode` glyph, which reads as "no code" rather than
                    // "loading" while the countdown is already running.
                    // Only a card with nothing on it should show the
                    // spinner; an already-displayed code stays put until the
                    // new one lands. Same rule `fetchAndDisplayQR` uses.
                    isLoadingQR = qrCodeImage == nil
                    let generation = LibraryService.loginGeneration
                    Task { @MainActor in
                        let image = await Task.detached(priority: .userInitiated) {
                            LibraryQRRenderer.image(from: payload)
                        }.value
                        // The 30 s refresh can rotate the payload while this
                        // render is in flight. Landing late must not put an
                        // expired matrix on screen under the new code's
                        // countdown — and must not store either, because a
                        // single-slot cache would evict the current entry and
                        // turn the next visit's memo hit into a miss.
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
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
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
        isLoadingQR = false
        consecutiveErrors = 0
        isLoggedIn = LibraryService.isTokenValid
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
    }
}
