import Foundation
import Network
import Observation
import os

/// Network reachability: an interface-up signal plus an on-demand captive-portal probe.
///
/// `isConnected` tracks `NWPath.status` (Android's `NET_CAPABILITY_INTERNET`): the link is up
/// with a default route, which says nothing about reaching the internet. `isReachable()` adds
/// Apple's probe (`NET_CAPABILITY_VALIDATED`), so refreshes behind a Wi-Fi login page bail out
/// before an NTUST or Moodle call fails with a confusing TLS or timeout error; pinned hosts
/// hard-fail there and `TLSPinningDelegate` cannot be relaxed at runtime. Results are cached for
/// `captiveCacheTTL` and dropped on any path change, so a burst of refreshes shares one probe.
@Observable
@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    /// Defaults to `false` (unknown / not-yet-observed) so a cold-launch
    /// caller in airplane mode doesn't optimistically attempt the 3 s
    /// probe before `NWPathMonitor` has had a chance to deliver
    /// `.unsatisfied`. First path update flips this within tens of ms
    /// when the link is actually up.
    private(set) var isConnected = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.tigerduck.NetworkMonitor")
    private let logger = Logger(
        subsystem: "org.ntust.app.TigerDuck",
        category: "Network.Monitor"
    )

    /// Apple's captive-portal probe, over HTTPS so ATS needs no `NSExceptionDomains` entry for
    /// plain HTTP. The body must contain the literal `Success` token to pass.
    ///
    /// Portals either reset HTTPS connections or serve their own certificate. A spoofed
    /// certificate lands in the TLS-error branch (fail closed); a reset or other connection loss
    /// lands in the catch-all (fail open). A portal that lets arbitrary HTTPS through passes the
    /// probe, but it would not intercept the pinned NTUST and Moodle hosts either.
    private static let captiveProbeURL = URL(string: "https://captive.apple.com/hotspot-detect.html")!
    private static let captiveProbeSuccessToken = "Success"
    private static let captiveProbeTimeout: TimeInterval = 3
    /// Cache window for the last probe result. Short enough that a
    /// captive portal sign-in (typically followed by a path update
    /// that invalidates the cache anyway) is reflected promptly; long
    /// enough that the common tab-switch flurry doesn't fan out to N
    /// concurrent probes.
    private static let captiveCacheTTL: TimeInterval = 30

    /// User-Agent matching Apple's own CaptiveNetworkSupport probe.
    /// Some captive portals filter the probe response by UA (whitelist
    /// the iOS CaptiveNetworkAgent string, reject unknown agents with
    /// 403/RST); using Apple's UA avoids that class of false-positive
    /// 'no internet' verdict.
    private static let captiveProbeUserAgent = "CaptiveNetworkSupport/1.0 wispr"

    private var cachedProbeResult: (value: Bool, at: Date)?
    /// Coalesces concurrent callers onto a single in-flight probe so
    /// five viewmodels racing on the same tab-switch produce one HTTPS
    /// round-trip rather than five. Stored with the epoch it started
    /// under so a path change can discard it instead of letting a
    /// new-arrival caller piggy-back on a stale-network probe.
    private var inFlightProbe: (epoch: UInt64, task: Task<Bool, Never>)?

    /// Bumps on every NWPath edge. Probes capture the current epoch at
    /// start; if the epoch advances before the probe completes (i.e. a
    /// path change happened mid-probe), the result is for the old
    /// network and the cache write-back is skipped. The awaiting
    /// caller then re-probes against the current network rather than
    /// acting on a stale verdict.
    private var probeEpoch: UInt64 = 0

    /// Set to `true` the first time `NWPathMonitor` delivers a path
    /// update. Until then, `isConnected == false` means "unknown" not
    /// "offline" — `isReachable()` waits briefly for the first update
    /// rather than spuriously returning false to a cold-launch caller
    /// (e.g. `TigerDuckApp.onAppear → backgroundSync()`) that races
    /// `NWPathMonitor`'s startup callback.
    private var hasReceivedPathUpdate = false

    /// Max wait at cold-launch for the first NWPathMonitor callback
    /// before assuming the network really is unreachable. NWPath
    /// delivers within tens of ms in practice; 500 ms is a generous
    /// ceiling that still bounds the bail-out for genuine airplane
    /// mode (which never delivers `.satisfied`).
    private static let firstPathUpdateTimeout: TimeInterval = 0.5

    // `nonisolated` so initialising `shared` from a non-main executor does not try to enter
    // @MainActor synchronously. The body touches only non-isolated `let` members; @MainActor
    // properties are written from the path handler's MainActor Task.
    nonisolated private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Any path change (gain, loss, interface swap) drops the cached verdict and
                // cancels the in-flight probe so its result is not stored as the new network's.
                // The epoch bump fences late write-backs that race the cancellation.
                self.probeEpoch &+= 1
                self.cachedProbeResult = nil
                self.inFlightProbe?.task.cancel()
                self.inFlightProbe = nil
                self.hasReceivedPathUpdate = true
                if self.isConnected != satisfied {
                    self.isConnected = satisfied
                }
            }
        }
        monitor.start(queue: queue)
    }

    /// Full reachability check: the interface is up and not behind a captive portal. Mirrors
    /// Android's `NetworkChecker.isAvailable()`. Call it at every refresh entry point that hits
    /// NTUST, Moodle or the library, so a captive portal shows a "log into Wi-Fi first" hint
    /// instead of a TLS-pin or timeout error from the API call.
    ///
    /// The probe takes about 100-300 ms cold and is then cached for `captiveCacheTTL`. Await it
    /// from a Task, not the render path; repeat calls within the TTL are nearly free.
    func isReachable() async -> Bool {
        // Cold launch: until the first path update, `isConnected` is still its default `false`.
        // Wait briefly so a healthy network is not reported offline at app start; airplane mode
        // still bails within the timeout.
        if !hasReceivedPathUpdate {
            await waitForFirstPathUpdate()
        }
        guard isConnected else { return false }

        if let cached = cachedProbeResult,
           Date().timeIntervalSince(cached.at) < Self.captiveCacheTTL {
            return cached.value
        }

        // Join an in-flight probe only from the current epoch. One started on a previous network
        // is about to be cancelled and its verdict discarded, so joining it would return that
        // stale value.
        if let existing = inFlightProbe, existing.epoch == probeEpoch {
            return await existing.task.value
        }

        let myEpoch = probeEpoch
        let task = Task { @MainActor [weak self] in
            let result = await Self.runProbe(logger: self?.logger)
            guard let self, self.probeEpoch == myEpoch else { return result }
            self.cachedProbeResult = (result, Date())
            self.inFlightProbe = nil
            return result
        }
        inFlightProbe = (myEpoch, task)
        let result = await task.value
        // The path changed during the probe and the caller wants the current network's verdict,
        // so probe again. The path change already cleared `inFlightProbe`, so the recursive call
        // starts fresh.
        if probeEpoch != myEpoch {
            return await isReachable()
        }
        return result
    }

    /// Polls `hasReceivedPathUpdate` at 25 ms granularity up to
    /// `firstPathUpdateTimeout`. Plain polling rather than a
    /// continuation list because the wait happens at most once per
    /// `NetworkMonitor` lifetime (after the first path callback the
    /// flag stays true), so the simplicity wins over the overhead of
    /// managing per-caller continuations with timeout cancellation.
    private func waitForFirstPathUpdate() async {
        let deadline = Date().addingTimeInterval(Self.firstPathUpdateTimeout)
        while !hasReceivedPathUpdate, Date() < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    /// Static so the in-flight Task can run the probe without holding
    /// `self` across the network hop — the result is written back via
    /// the closure capture.
    private static func runProbe(logger: Logger?) async -> Bool {
        var request = URLRequest(url: captiveProbeURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = captiveProbeTimeout
        request.setValue(captiveProbeUserAgent, forHTTPHeaderField: "User-Agent")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = captiveProbeTimeout
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        do {
            // The per-task delegate refuses any 3xx. Otherwise a portal that redirects to its
            // login page would hand its HTML to the body check, and any "Success" substring in it
            // would pass the probe.
            let (data, response) = try await session.data(
                for: request,
                delegate: NoRedirectProbeDelegate(),
            )
            guard let http = response as? HTTPURLResponse else {
                logger?.info("captive probe: non-HTTP response")
                return false
            }
            guard http.statusCode == 200 else {
                logger?.info("captive probe: unexpected status \(http.statusCode, privacy: .public)")
                return false
            }
            guard let body = String(data: data, encoding: .utf8),
                  body.contains(captiveProbeSuccessToken) else {
                // A 200 without Apple's token is most likely a portal serving its own page over
                // transparent HTTPS, so treat it as captive.
                logger?.info("captive probe: body missing success token — captive portal likely")
                return false
            }
            return true
        } catch let urlError as URLError where Self.isTLSError(urlError.code) {
            // Portals intercept HTTPS with their own certificate under a private MDM or portal
            // CA, so a TLS failure is a near-certain captive signal: the pinned hosts would fail
            // the same way. Fail closed so the caller takes the offline path, not a doomed call.
            logger?.info("captive probe: TLS error \(urlError.code.rawValue, privacy: .public) — captive portal likely")
            return false
        } catch {
            // Other errors, such as DNS failures and timeouts, are ambiguous. Fail open so a
            // captive.apple.com hiccup does not mark every view model offline; the real API call
            // surfaces its own error if NTUST is unreachable.
            logger?.info("captive probe inconclusive (\(error.localizedDescription, privacy: .public)) — failing open")
            return true
        }
    }

    /// URLError codes that indicate the probe's TLS handshake failed
    /// or the server presented an untrusted / spoofed cert — the
    /// fingerprint of a captive-portal HTTPS intercept. Listed
    /// explicitly (not `error is URLError && code ~= tls*`) so a
    /// future Foundation addition doesn't silently flip a non-TLS
    /// error into the fail-closed bucket.
    private static func isTLSError(_ code: URLError.Code) -> Bool {
        switch code {
        case .secureConnectionFailed,
             .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired:
            return true
        default:
            return false
        }
    }
}

/// Task-delegate that refuses any 3xx redirect during the captive
/// probe.
private final class NoRedirectProbeDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
