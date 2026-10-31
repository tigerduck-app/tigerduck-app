#if DEBUG && os(iOS)
import Foundation
import Network
import Security

/// The probe's DNS and transport stages, and the timeout every stage runs under.
nonisolated enum DevMailNetworkProbe {
    private static let queue = DispatchQueue(label: "org.ntust.app.TigerDuck.DevMailConnectionProbe")

    static func dnsStep(host: String, port: Int) async -> DevMailProbeStep {
        let start = ContinuousClock.now
        let resolution = await withTimeout(DevMailConnectionProbe.stageTimeout) { await resolveOffThread(host: host, port: port) }
        let outcome: DevMailProbeOutcome
        switch resolution {
        case .some(.addresses(let addresses)) where !addresses.isEmpty:
            outcome = .passed(addresses.joined(separator: ", "))
        case .some(.addresses):
            outcome = .failed("getaddrinfo() succeeded but returned no address")
        case .some(.failed(let code)):
            outcome = .failed("getaddrinfo() = \(code) (\(String(cString: gai_strerror(code))))")
        case nil:
            outcome = .failed("timed out after \(DevMailConnectionProbe.stageTimeout) — the resolver never answered")
        }
        return DevMailProbeStep(stage: .dns, outcome: outcome, milliseconds: milliseconds(since: start))
    }

    private enum Resolution: Sendable {
        case addresses([String])
        case failed(Int32)
    }

    /// `getaddrinfo` blocks and cannot be cancelled, so it runs on a global-queue thread rather
    /// than a cooperative-pool one. A lookup that outlives the timeout finishes there with nobody
    /// reading it, which is the price of asking the system resolver the same question the rest of
    /// the app asks it.
    private static func resolveOffThread(host: String, port: Int) async -> Resolution {
        await withCheckedContinuation { (continuation: CheckedContinuation<Resolution, Never>) in
            let resumer = OneShotResumer(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                resumer.resume(resolve(host: host, port: port))
            }
        }
    }

    private static func resolve(host: String, port: Int) -> Resolution {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var head: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &head)
        guard status == 0, let head else { return .failed(status) }
        defer { freeaddrinfo(head) }

        var addresses: [String] = []
        var node: UnsafeMutablePointer<addrinfo>? = head
        while let current = node {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let named = getnameinfo(
                current.pointee.ai_addr, current.pointee.ai_addrlen,
                &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST
            )
            if named == 0 {
                let address = String(cString: buffer)
                if !address.isEmpty, !addresses.contains(address) { addresses.append(address) }
            }
            node = current.pointee.ai_next
        }
        return .addresses(addresses)
    }

    static func transportStep(
        _ stage: DevMailProbeStage,
        host: String,
        port: Int,
        scheme: MailTransportScheme
    ) async -> DevMailProbeStep {
        if stage == .tls, scheme != .implicitTLS {
            return DevMailProbeStep(
                stage: .tls,
                outcome: .notRun("\(scheme.title) negotiates inside the protocol — see CONNECT"),
                milliseconds: nil
            )
        }
        guard let number = UInt16(exactly: port), let endpointPort = NWEndpoint.Port(rawValue: number) else {
            return DevMailProbeStep(stage: stage, outcome: .failed("port \(port) is not a port"), milliseconds: nil)
        }
        let start = ContinuousClock.now
        let result = await connect(host: host, port: endpointPort, tls: stage == .tls)
        let outcome: DevMailProbeOutcome
        switch result {
        case .some(.ready(let detail)):
            outcome = .passed(detail)
        case .some(.failed(let error)):
            outcome = .failed(DevMailProbeErrors.describe(error))
        case nil:
            outcome = .failed(
                stage == .tls
                    ? "timed out after \(DevMailConnectionProbe.stageTimeout) — the handshake never completed"
                    : "timed out after \(DevMailConnectionProbe.stageTimeout) — no answer, which is what a filtered port looks like"
            )
        }
        return DevMailProbeStep(stage: stage, outcome: outcome, milliseconds: milliseconds(since: start))
    }

    private enum TransportResult: Sendable {
        case ready(String)
        case failed(NWError)
    }

    private static func connect(host: String, port: NWEndpoint.Port, tls: Bool) async -> TransportResult? {
        let parameters: NWParameters
        if tls {
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
            parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        } else {
            parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        }
        let connection = ProbeConnection(NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters))
        let result = await withTimeout(DevMailConnectionProbe.stageTimeout) { await connection.wait(on: queue) }
        connection.close()
        return result
    }

    private final class ProbeConnection: @unchecked Sendable {
        private let connection: NWConnection

        init(_ connection: NWConnection) { self.connection = connection }

        func wait(on queue: DispatchQueue) async -> TransportResult {
            await withCheckedContinuation { (continuation: CheckedContinuation<TransportResult, Never>) in
                let resumer = OneShotResumer(continuation)
                connection.stateUpdateHandler = { [connection] state in
                    switch state {
                    case .ready:
                        resumer.resume(.ready(DevMailNetworkProbe.describe(ready: connection)))
                    // `.waiting` is a result, not a stage on the way to one: Network keeps
                    // retrying a refused or unroutable connection indefinitely, and the error it
                    // is waiting on is exactly the diagnosis.
                    case .waiting(let error), .failed(let error):
                        resumer.resume(.failed(error))
                    case .cancelled:
                        resumer.resume(.failed(NWError.posix(.ECANCELED)))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        }

        func close() {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
    }

    private static func describe(ready connection: NWConnection) -> String {
        var parts: [String] = []
        if let remote = connection.currentPath?.remoteEndpoint {
            parts.append(String(describing: remote))
        }
        if let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
            let version = sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata)
            parts.append(DevMailProbeErrors.tlsVersionName(version.rawValue))
        }
        return parts.isEmpty ? "connected" : parts.joined(separator: ", ")
    }

    /// Not a task group: a group does not return until every child has finished, and not waiting
    /// for work that has not finished is the whole point here. SwiftMail's IMAP and SMTP commands
    /// ignore task cancellation, and a filtered port is exactly the case where a socket sits for a
    /// minute or more — so the unfinished work is left to end on its own, with nobody reading it,
    /// while the stage reports the hang. Every connection this probe opens is held by its caller
    static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        _ work: @escaping @Sendable () async -> T
    ) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let resumer = OneShotResumer(continuation)
            Task { resumer.resume(await work()) }
            Task {
                try? await Task.sleep(for: timeout)
                resumer.resume(nil)
            }
        }
    }

    final class OneShotResumer<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?

        init(_ continuation: CheckedContinuation<T, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: T) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = (ContinuousClock.now - start).components
        return Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
    }
}
#endif
