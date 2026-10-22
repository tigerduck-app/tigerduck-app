import Foundation
import Network
import Observation
import os

@Observable
@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private(set) var isConnected = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.tigerduck.NetworkMonitor")
    private let logger = Logger(
        subsystem: "org.ntust.app.TigerDuck",
        category: "Network.Monitor"
    )

    /// Apple's captive-portal probe, over HTTPS so ATS needs no `NSExceptionDomains` entry for
    /// plain HTTP. The body must contain the literal `Success` token to pass.
    private static let captiveProbeURL = URL(string: "https://captive.apple.com/hotspot-detect.html")!
    private static let captiveProbeSuccessToken = "Success"
    private static let captiveProbeTimeout: TimeInterval = 3
    private static let captiveCacheTTL: TimeInterval = 30

    /// User-Agent matching Apple's own CaptiveNetworkSupport probe.
    /// Some captive portals filter the probe response by UA (whitelist
    /// the iOS CaptiveNetworkAgent string, reject unknown agents with
    /// 403/RST); using Apple's UA avoids that class of false-positive
    /// 'no internet' verdict.
    private static let captiveProbeUserAgent = "CaptiveNetworkSupport/1.0 wispr"

    private var cachedProbeResult: (value: Bool, at: Date)?
    private var inFlightProbe: (epoch: UInt64, task: Task<Bool, Never>)?

    private var probeEpoch: UInt64 = 0

    private var hasReceivedPathUpdate = false

    private static let firstPathUpdateTimeout: TimeInterval = 0.5

    nonisolated private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
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

    func isReachable() async -> Bool {
        if !hasReceivedPathUpdate {
            await waitForFirstPathUpdate()
        }
        guard isConnected else { return false }

        if let cached = cachedProbeResult,
           Date().timeIntervalSince(cached.at) < Self.captiveCacheTTL {
            return cached.value
        }

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
        if probeEpoch != myEpoch {
            return await isReachable()
        }
        return result
    }

    private func waitForFirstPathUpdate() async {
        let deadline = Date().addingTimeInterval(Self.firstPathUpdateTimeout)
        while !hasReceivedPathUpdate, Date() < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

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
                logger?.info("captive probe: body missing success token — captive portal likely")
                return false
            }
            return true
        } catch let urlError as URLError where Self.isTLSError(urlError.code) {
            logger?.info("captive probe: TLS error \(urlError.code.rawValue, privacy: .public) — captive portal likely")
            return false
        } catch {
            logger?.info("captive probe inconclusive (\(error.localizedDescription, privacy: .private)) — failing open")
            return true
        }
    }

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
