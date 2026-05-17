import SwiftUI
import CoreGraphics
import Combine

@MainActor
@Observable
final class LibraryQRViewModel {
    var qrImage: UIImage?
    var countdown: Int = 30
    var isLoading = false
    var errorMessage: String?
    var username: String?
    var hasCredentials: Bool

    /// Same backoff schedule the phone uses — keeps a flapping 5xx on
    /// the library API from hammering the watch radio every 30s and
    /// killing battery. Holds at 300s after the 3rd consecutive error.
    private static let backoffSchedule: [TimeInterval] = [60, 120, 300]
    private var consecutiveErrors = 0

    private var refreshTimer: Timer?
    private var countdownTimer: Timer?
    private var credentialsCancellable: AnyCancellable?

    private let store: WatchLibraryCredentialsStore

    init(store: WatchLibraryCredentialsStore? = nil) {
        let resolvedStore = store ?? WatchLibraryCredentialsStore.shared
        self.store = resolvedStore
        self.hasCredentials = resolvedStore.hasCredentials
        self.username = resolvedStore.currentUsername()

        // React to credential set/wipe pushes so the empty/loaded state
        // flips without requiring a view rebuild.
        self.credentialsCancellable = resolvedStore.$hasCredentials
            .receive(on: RunLoop.main)
            .sink { [weak self] newValue in
                guard let self else { return }
                self.hasCredentials = newValue
                self.username = self.store.currentUsername()
                if newValue {
                    self.startRefreshCycle()
                } else {
                    self.stopTimers()
                    self.qrImage = nil
                    self.errorMessage = nil
                }
            }
    }

    deinit {
        Task { @MainActor [weak self] in
            self?.stopTimers()
        }
    }

    // MARK: - Lifecycle

    func onAppear() {
        // Refresh immediately if we have no QR or it's clearly stale.
        if hasCredentials {
            if qrImage == nil || countdown <= 5 {
                fetchAndRender()
            }
            if refreshTimer == nil {
                startRefreshCycle()
            }
        }
    }

    func onDisappear() {
        // Stop the 30s radio churn while the page is off-screen. Page
        // tabs on watchOS can sit unfocused for hours.
        stopTimers()
    }

    // MARK: - Fetch + render

    private func startRefreshCycle() {
        fetchAndRender()
        refreshTimer?.invalidate()
        refreshTimer = Self.scheduleCommonModeTimer(interval: 30, repeats: true) { [weak self] in
            self?.fetchAndRender()
        }
    }

    private func fetchAndRender() {
        Task { @MainActor in
            isLoading = qrImage == nil
            errorMessage = nil
            do {
                let payload = try await WatchLibraryService.generateQRCode()
                guard let image = Self.makeQRImage(from: payload) else {
                    throw WatchLibraryServiceError.qrGenerationFailed("QR payload is too large")
                }
                qrImage = image
                username = store.currentUsername()
                countdown = 30
                isLoading = false
                consecutiveErrors = 0
                restartCountdown()
            } catch WatchLibraryServiceError.credentialsNotFound {
                // TTL purge or no credentials — mirror store state.
                isLoading = false
                hasCredentials = false
                qrImage = nil
                stopTimers()
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
                consecutiveErrors += 1
                rescheduleAfterError()
            }
        }
    }

    private func rescheduleAfterError() {
        let idx = min(consecutiveErrors - 1, Self.backoffSchedule.count - 1)
        let interval = Self.backoffSchedule[max(0, idx)]
        refreshTimer?.invalidate()
        refreshTimer = Self.scheduleCommonModeTimer(interval: interval, repeats: false) { [weak self] in
            self?.fetchAndRender()
        }
    }

    private func restartCountdown() {
        countdown = 30
        countdownTimer?.invalidate()
        countdownTimer = Self.scheduleCommonModeTimer(interval: 1, repeats: true) { [weak self] in
            guard let self else { return }
            if self.countdown > 0 { self.countdown -= 1 }
        }
    }

    private func stopTimers() {
        refreshTimer?.invalidate(); refreshTimer = nil
        countdownTimer?.invalidate(); countdownTimer = nil
    }

    /// `Timer.scheduledTimer` registers in `.default` mode only, so the timer
    /// pauses while the user scrolls a SwiftUI view (which runs the main
    /// run loop in `.tracking` mode) and then "catches up" by firing rapidly
    /// when scrolling stops. Registering in `.common` includes both
    /// `.default` and `.tracking`, so the countdown keeps decrementing
    /// smoothly while paging or scrolling.
    private static func scheduleCommonModeTimer(
        interval: TimeInterval,
        repeats: Bool,
        action: @escaping @MainActor () -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats) { _ in
            Task { @MainActor in action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// Render the matrix to a `UIImage` via CoreGraphics. We can't reuse the
    /// phone's `CIFilter.qrCodeGenerator()` here — CoreImage is unavailable
    /// on watchOS. `WatchQRCodeGenerator` computes the module matrix in
    /// pure Swift; this just fills dark cells into a grayscale bitmap.
    private static func makeQRImage(from payload: String) -> UIImage? {
        guard let matrix = WatchQRCodeGenerator.encode(payload, ecc: .medium) else {
            return nil
        }

        // 1-module quiet zone on each side keeps the bottom edge readable
        // against the watch's white card background; the QR spec actually
        // calls for a 4-module quiet zone but the parent view already
        // pads the white surround.
        let quiet = 1
        let modulesPerSide = matrix.size + quiet * 2
        let pixelsPerModule = 6
        let pixelsPerSide = modulesPerSide * pixelsPerModule

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: pixelsPerSide,
            height: pixelsPerSide,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: pixelsPerSide, height: pixelsPerSide))

        context.setFillColor(gray: 0, alpha: 1)
        for y in 0..<matrix.size {
            for x in 0..<matrix.size {
                guard matrix.module(x: x, y: y) else { continue }
                // CG origin is bottom-left; we flip Y so the QR reads
                // top-to-bottom on screen the same way as on the phone.
                let px = (x + quiet) * pixelsPerModule
                let py = (matrix.size - 1 - y + quiet) * pixelsPerModule
                context.fill(CGRect(x: px, y: py, width: pixelsPerModule, height: pixelsPerModule))
            }
        }

        guard let cgImage = context.makeImage() else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
