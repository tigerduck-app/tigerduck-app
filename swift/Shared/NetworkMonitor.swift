import Foundation
import Network
import Observation
import os

/// Network reachability — interface-up signal + on-demand captive
/// portal probe.
///
/// `isConnected` (sync, MainActor) tracks NWPath.status — equivalent to
/// Android's `NetworkCapabilities.NET_CAPABILITY_INTERNET`: link is up,
/// routing table has a default gateway. It says nothing about whether
/// traffic actually escapes to the public internet.
///
/// `isReachable()` (async, MainActor) layers Apple's captive-portal
/// probe on top — equivalent to Android's `NET_CAPABILITY_VALIDATED`.
/// Hotel / airport / campus Wi-Fi that intercepts requests with a
/// login page is reported `isConnected == true` but
/// `isReachable() == false`, so refresh paths can bail out gracefully
/// instead of letting the actual NTUST / Moodle call surface a
/// confusing TLS or timeout error.
///
/// Pinned hosts (`*.ntust.edu.tw`, `api.lib.ntust.edu.tw`) hard-fail
/// when a captive portal intercepts them — the per-host SPKI check in
/// `TLSPinningDelegate` cannot be relaxed at runtime. This pre-flight
/// is the only place we can spare the user that error.
///
/// Probe results are memoised for `captiveCacheTTL` (and invalidated
/// on any NWPath change) so a tab-switch flurry that fires five
/// concurrent refreshes does not produce five round-trips to
/// captive.apple.com.
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

    /// Apple's canonical captive-portal probe. We hit the HTTPS variant
    /// so the existing ATS posture stays untouched (no
    /// `NSExceptionDomains` for plain HTTP). Body MUST contain the
    /// literal `Success` token for the probe to count as passed.
    ///
    /// HTTPS catches the common captive cases: portals either TCP-RST
    /// HTTPS connections or serve their own cert. Cert-spoof falls
    /// into the TLS-error branch below (fail-closed); RST / generic
    /// connection loss falls into the catch-all (fail-open) — see the
    /// rationale on each branch. The rare portal that transparently
    /// allows arbitrary HTTPS would pass this probe, but a portal in
    /// that mode wouldn't intercept the pinned NTUST / Moodle hosts
    /// either, so the user wouldn't have hit the failure we're trying
    /// to spare them.
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

    // `nonisolated` init so static-let initialisation triggered from a
    // non-main executor doesn't try to enter @MainActor synchronously.
    // The body only touches non-isolated `let` members; @MainActor
    // properties are written from the path handler's MainActor Task.
    nonisolated private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Any path edge — gain, loss, interface swap — drops
                // the cached probe verdict and cancels any in-flight
                // probe so its result isn't written back as the new
                // network's verdict. Epoch bump fences late write-
                // backs that race the cancellation.
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

    /// Full reachability check: interface up AND not behind a captive
    /// portal. Mirrors the Android `NetworkChecker.isAvailable()` call
    /// that gates `HomeViewModel.refresh()` etc. — use this at any
    /// refresh entry point that hits NTUST / Moodle / library, so a
    /// captive portal surfaces a "log into Wi-Fi first" hint instead
    /// of a TLS-pin or timeout error from the actual API call.
    ///
    /// Probe takes ~100-300 ms cold and is cached for `captiveCacheTTL`
    /// thereafter; callers should `await` from a Task, not the render
    /// path, but the cache makes a tab-switch flurry effectively free.
    func isReachable() async -> Bool {
        // Cold-launch race: callers may invoke `isReachable()` before
        // `NWPathMonitor` has delivered its first path update, at
        // which point `isConnected` is still its default `false`.
        // Wait briefly so a healthy network isn't misreported as
        // offline at app start; airplane mode still bails within the
        // timeout.
        if !hasReceivedPathUpdate {
            await waitForFirstPathUpdate()
        }
        guard isConnected else { return false }

        if let cached = cachedProbeResult,
           Date().timeIntervalSince(cached.at) < Self.captiveCacheTTL {
            return cached.value
        }

        // Only join an in-flight probe if it belongs to the current
        // epoch — a probe started under a previous network is about
        // to be cancelled and its verdict discarded; piggy-backing on
        // it would just hand back that stale value.
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
        // Path changed while we were probing — caller wants the
        // current network's verdict, not the old one's. Re-probe
        // (the cancelled task already cleared `inFlightProbe`, so
        // the recursive call starts fresh).
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
            // Per-task delegate refuses any 3xx. Without this, a portal
            // that 302-redirects HTTPS to its login page would deliver
            // portal HTML to the probe body and any coincidental
            // "Success" substring (e.g. "Login successful to continue")
            // would false-positive the check.
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
                // 200 with a body that doesn't carry Apple's literal
                // token — most likely a captive portal serving its own
                // page through transparent HTTPS. Definite captive
                // signal; bail false.
                logger?.info("captive probe: body missing success token — captive portal likely")
                return false
            }
            return true
        } catch let urlError as URLError where Self.isTLSError(urlError.code) {
            // Captive portals routinely intercept HTTPS by serving
            // their own cert under a private MDM/portal CA. TLS-class
            // probe failures are a near-definite captive signal — the
            // pinned NTUST / library hosts would fail with the exact
            // same TLS error this preflight exists to spare the user.
            // Fail-closed so the caller falls back to the offline
            // path instead of proceeding to a doomed pinned call.
            logger?.info("captive probe: TLS error \(urlError.code.rawValue, privacy: .public) — captive portal likely")
            return false
        } catch {
            // Other errors (DNS, timeout, transient Apple-side 5xx
            // surfacing as URLError, redirect cancel from the delegate
            // above) are ambiguous: could be captive, could be a
            // perfectly fine network where captive.apple.com is briefly
            // flaky or where Apple changed the HTTPS response format.
            // Fail-open so a brief Apple-endpoint hiccup doesn't
            // globally regress every viewmodel to 'no internet'; the
            // real API call will surface its own error if the network
            // genuinely can't reach NTUST.
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
