import SwiftUI
import CoreImage.CIFilterBuiltins

@Observable
final class LibraryViewModel {
    var qrCodeImage: UIImage?
    var qrPayload: String?
    var countdown: Int = 30
    var isLoadingQR = false
    var errorMessage: String?

    var isLoggedIn = false
    var isLoggingIn = false

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
            stopTimers()
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
            do {
                let payload = try await LibraryService.generateQRCode()
                // Rasterise off the main actor: a cold CIContext plus the
                // CGImage render was a visible hitch on older phones.
                let image = await Task.detached(priority: .userInitiated) {
                    Self.generateQRImage(from: payload)
                }.value
                qrPayload = payload
                qrCodeImage = image
                countdown = 30
                isLoadingQR = false
                consecutiveErrors = 0
                restartCountdown()
            } catch {
                errorMessage = error.localizedDescription
                isLoadingQR = false
                if !LibraryService.isTokenValid {
                    isLoggedIn = false
                    consecutiveErrors = 0
                    stopTimers()
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

    /// One context for the app's lifetime — creating one per QR compiles
    /// Core Image's Metal pipeline every 30 s.
    nonisolated(unsafe) private static let ciContext = CIContext()  // CIContext is thread-safe

    nonisolated private static func generateQRImage(from string: String) -> UIImage? {
        // Plain SDR black/white render. HDR brightness is applied at draw
        // time by `HDRQRCodeImage` via a Metal shader against an EDR-enabled
        // CAMetalLayer — doing it here through CoreImage's filter chain
        // proved unreliable (false-color clamping + SwiftUI not tagging
        // synthetic UIImages as HDR).
        let context = ciContext
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let ciImage = filter.outputImage else { return nil }
        let scale: CGFloat = 10
        let transformed = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Timers

    private func startQRRefreshCycle() {
        fetchAndDisplayQR()

        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.fetchAndDisplayQR()
        }
    }

    private func restartCountdown() {
        countdown = 30
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

    func stopTimers() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    deinit {
        stopTimers()
    }
}
