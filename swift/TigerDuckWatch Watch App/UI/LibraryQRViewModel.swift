import SwiftUI
import CoreGraphics
import Combine
import WatchConnectivity

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
                    self.renderedPayload = nil
                    self.errorMessage = nil
                    LibraryQRCache.shared.clear()
                }
            }
    }

    deinit {
        Task { @MainActor [weak self] in
            self?.stopTimers()
        }
    }

    // MARK: - Lifecycle

    /// The payload `qrImage` was rendered from, so a cached code is not
    /// re-rasterised on every page switch.
    private var renderedPayload: String?

    func onAppear() {
        // `startRefreshCycle` reuses the cached code when it still has
        // enough life left, so page switches don't burn a fetch.
        if hasCredentials, refreshTimer == nil {
            startRefreshCycle()
        }
    }

    func onDisappear() {
        // Stop the 30s radio churn while the page is off-screen. Page
        // tabs on watchOS can sit unfocused for hours.
        stopTimers()
    }

    // MARK: - Fetch + render

    /// A cached code with at least `LibraryQRCache.reuseThreshold` seconds
    /// left is shown again with its countdown resumed and the next fetch
    /// scheduled for when it runs out; otherwise fetch now and every 30 s.
    private func startRefreshCycle() {
        refreshTimer?.invalidate()
        let cache = LibraryQRCache.shared
        if let payload = cache.reusable() {
            let remaining = cache.remaining()
            if renderedPayload != payload || qrImage == nil, let image = Self.makeQRImage(from: payload) {
                qrImage = image
                renderedPayload = payload
                isLoading = false
            }
            restartCountdown(from: remaining)
            refreshTimer = Self.scheduleCommonModeTimer(interval: TimeInterval(remaining), repeats: false) { [weak self] in
                self?.startRefreshCycle()
            }
            return
        }

        fetchAndRender()
        refreshTimer = Self.scheduleCommonModeTimer(interval: 30, repeats: true) { [weak self] in
            self?.fetchAndRender()
        }
    }

    private func fetchAndRender() {
        Task { @MainActor in
            isLoading = qrImage == nil
            errorMessage = nil
            do {
                let (payload, remaining) = try await fetchPayload()
                guard let image = Self.makeQRImage(from: payload) else {
                    throw WatchLibraryServiceError.qrGenerationFailed("QR payload is too large")
                }
                LibraryQRCache.shared.store(payload, remaining: remaining)
                qrImage = image
                renderedPayload = payload
                username = store.currentUsername()
                isLoading = false
                consecutiveErrors = 0
                restartCountdown(from: remaining)
            } catch WatchLibraryServiceError.credentialsNotFound {
                // TTL purge or no credentials — mirror store state.
                isLoading = false
                hasCredentials = false
                qrImage = nil
                renderedPayload = nil
                stopTimers()
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
                consecutiveErrors += 1
                rescheduleAfterError()
            }
        }
    }

    /// Phone first while it is in Bluetooth range: no watch-side internet
    /// needed, and the two screens show the same code. Then the watch's
    /// own link — skipping the captive-portal pre-flight when the phone is
    /// reachable, since the watch's traffic rides the phone's connection
    /// then, and running it otherwise so a hotel Wi-Fi surfaces the
    /// "log into Wi-Fi" hint instead of an opaque TLS-pin error.
    private func fetchPayload() async throws -> (payload: String, remaining: Int) {
        let phoneReachable = WCSession.isSupported() && WCSession.default.isReachable
        var phoneError: Error?
        if phoneReachable {
            do { return try await Self.requestFromPhone() } catch { phoneError = error }
        }
        if !phoneReachable, !(await NetworkMonitor.shared.isReachable()) {
            throw WatchLibraryServiceError.offline
        }
        do {
            return (try await WatchLibraryService.generateQRCode(), LibraryQRCache.lifetime)
        } catch WatchLibraryServiceError.credentialsNotFound {
            throw WatchLibraryServiceError.credentialsNotFound
        } catch {
            throw phoneError ?? error
        }
    }

    private static func requestFromPhone() async throws -> (payload: String, remaining: Int) {
        try await withCheckedThrowingContinuation { continuation in
            WCSession.default.sendMessage(
                [WatchWireFormat.MessageKey.kind: WatchWireFormat.MessageKind.libraryQRRequest],
                replyHandler: { reply in
                    if let payload = reply[WatchWireFormat.LibraryQRKey.payload] as? String, !payload.isEmpty {
                        let remaining = reply[WatchWireFormat.LibraryQRKey.remaining] as? Int ?? LibraryQRCache.lifetime
                        continuation.resume(returning: (payload, remaining))
                    } else {
                        let message = reply[WatchWireFormat.LibraryQRKey.error] as? String ?? "no payload"
                        continuation.resume(throwing: WatchLibraryServiceError.qrGenerationFailed(message))
                    }
                },
                errorHandler: { continuation.resume(throwing: $0) }
            )
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

    private func restartCountdown(from seconds: Int = LibraryQRCache.lifetime) {
        countdown = seconds
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
