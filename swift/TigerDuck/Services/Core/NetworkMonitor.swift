import Foundation
import Network
import Observation
import os

/// Network reachability — interface-up signal + on-demand captive
/// portal probe.
///
/// `isConnected` (sync) tracks NWPath.status — equivalent to Android's
/// `NetworkCapabilities.NET_CAPABILITY_INTERNET`: link is up, routing
/// table has a default gateway. It says nothing about whether traffic
/// actually escapes to the public internet.
///
/// `isReachable()` (async) layers Apple's captive-portal probe on top —
/// equivalent to Android's `NET_CAPABILITY_VALIDATED`. Hotel / airport /
/// campus Wi-Fi that intercepts requests with a login page is reported
/// `isConnected == true` but `isReachable() == false`, so refresh paths
/// can bail out gracefully instead of letting the actual NTUST / Moodle
/// call surface a confusing TLS or timeout error.
///
/// Pinned hosts (`*.ntust.edu.tw`, `api.lib.ntust.edu.tw`) hard-fail
/// when a captive portal intercepts them — ATS `NSPinnedDomains` cannot
/// be relaxed at runtime. The pre-flight `isReachable()` check is the
/// only place we can spare the user that error.
@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private(set) var isConnected = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.tigerduck.NetworkMonitor")
    private let logger = Logger(
        subsystem: "org.ntust.app.TigerDuck",
        category: "Network.Monitor"
    )

    /// Apple's canonical captive-portal probe. We hit the HTTPS variant
    /// so the existing ATS posture stays untouched (no
    /// `NSExceptionDomains` for plain HTTP). Body MUST contain the
    /// literal `Success` token for the probe to count as passed —
    /// anything else (login page HTML, redirect, captive portal
    /// intercept that hard-blocks HTTPS, timeout) means the user is
    /// captured or has no actual internet egress.
    ///
    /// HTTPS still catches the common captive-portal cases: most
    /// portals either TCP-RST HTTPS connections (URLSession sees a
    /// connection error) or serve their own cert (TLS handshake fails).
    /// The rare portal that transparently allows arbitrary HTTPS would
    /// pass this probe, but a portal in that mode wouldn't intercept
    /// our pinned NTUST / Moodle hosts either, so the user wouldn't
    /// have hit the failure we're trying to spare them.
    private static let captiveProbeURL = URL(string: "https://captive.apple.com/hotspot-detect.html")!
    private static let captiveProbeSuccessToken = "Success"
    private static let captiveProbeTimeout: TimeInterval = 3

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self, self.isConnected != satisfied else { return }
                self.isConnected = satisfied
            }
        }
        monitor.start(queue: queue)
    }

    /// Full reachability check: interface up AND not behind a captive
    /// portal. Mirrors the Android `NetworkChecker.isAvailable()` call
    /// that gates `HomeViewModel.refresh()` etc. — use this at any
    /// refresh entry point that hits NTUST / Moodle / library, so a
    /// captive portal surfaces a "log into Wi-Fi first" hint instead of
    /// a TLS-pin or timeout error from the actual API call.
    ///
    /// Probe takes ~100-300 ms warm, up to `captiveProbeTimeout` cold;
    /// callers should `await` from a Task, not from the render path.
    func isReachable() async -> Bool {
        guard isConnected else { return false }
        return await probeCaptive()
    }

    private func probeCaptive() async -> Bool {
        var request = URLRequest(url: Self.captiveProbeURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = Self.captiveProbeTimeout

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.captiveProbeTimeout
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                logger.info("captive probe: unexpected status \((response as? HTTPURLResponse)?.statusCode ?? -1, privacy: .public)")
                return false
            }
            guard let body = String(data: data, encoding: .utf8),
                  body.contains(Self.captiveProbeSuccessToken) else {
                // Captive portals intercept the request and serve their
                // own HTML (login page, redirect). The body won't carry
                // Apple's "Success" token, so we bail.
                logger.info("captive probe: body missing success token — captive portal likely")
                return false
            }
            return true
        } catch {
            logger.info("captive probe failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
