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
    /// HTTPS connections or serve their own cert (TLS handshake fails),
    /// and either way the probe falls into the catch branch. The rare
    /// portal that transparently allows arbitrary HTTPS would pass
    /// this probe, but a portal in that mode wouldn't intercept the
    /// pinned NTUST / Moodle hosts either, so the user wouldn't have
    /// hit the failure we're trying to spare them.
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
    /// round-trip rather than five.
    private var inFlightProbe: Task<Bool, Never>?

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
                // the cached probe verdict; the next caller re-probes
                // against the new network.
                self.cachedProbeResult = nil
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
        guard isConnected else { return false }

        if let cached = cachedProbeResult,
           Date().timeIntervalSince(cached.at) < Self.captiveCacheTTL {
            return cached.value
        }

        if let existing = inFlightProbe {
            return await existing.value
        }

        let task = Task { @MainActor [weak self] in
            let result = await Self.runProbe(logger: self?.logger)
            self?.cachedProbeResult = (result, Date())
            self?.inFlightProbe = nil
            return result
        }
        inFlightProbe = task
        return await task.value
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
        } catch {
            // Probe-endpoint trouble (timeout, DNS fail, transient
            // Apple-side 5xx surfacing as URLError, redirect cancel
            // from the delegate above) is ambiguous: could be captive,
            // could be a perfectly fine network where captive.apple.com
            // is briefly flaky or where Apple changed the HTTPS
            // response format. Fail-open so a brief Apple-endpoint
            // hiccup doesn't globally regress every viewmodel to 'no
            // internet'; the real API call will surface its own error
            // if the network genuinely can't reach NTUST.
            logger?.info("captive probe inconclusive (\(error.localizedDescription, privacy: .public)) — failing open")
            return true
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
