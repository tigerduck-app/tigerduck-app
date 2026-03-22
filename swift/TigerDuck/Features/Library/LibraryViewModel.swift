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

    // MARK: - Lifecycle

    func load() {
        guard !hasLoaded else { return }
        hasLoaded = true
        isLoggedIn = LibraryService.isTokenValid

        // Pre-fill username from stored library credentials or NTUST student ID
        if let stored = LibraryService.storedUsername {
            libUsername = stored
        } else if let ntustId = KeychainManager.load(key: "ntust_student_id").flatMap({ String(data: $0, encoding: .utf8) }) {
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
        if hasLoaded && isLoggedIn && refreshTimer == nil {
            startQRRefreshCycle()
        }
    }

    func onDisappear() {
        stopTimers()
    }

    // MARK: - Login

    func loginAndStart() {
        Task { @MainActor in
            isLoggingIn = true
            errorMessage = nil
            do {
                try await LibraryService.login(
                    username: libUsername.trimmingCharacters(in: .whitespaces).uppercased(),
                    password: libPassword
                )
                libPassword = ""
                isLoggedIn = true
                isLoggingIn = false
                startQRRefreshCycle()
            } catch {
                errorMessage = error.localizedDescription
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
                qrPayload = payload
                qrCodeImage = Self.generateQRImage(from: payload)
                countdown = 30
                isLoadingQR = false
                restartCountdown()
            } catch {
                errorMessage = error.localizedDescription
                isLoadingQR = false
                if !LibraryService.isTokenValid {
                    isLoggedIn = false
                    stopTimers()
                }
            }
        }
    }

    private static func generateQRImage(from string: String) -> UIImage? {
        let context = CIContext()
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
