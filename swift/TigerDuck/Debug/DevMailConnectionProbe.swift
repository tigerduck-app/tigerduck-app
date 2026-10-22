#if DEBUG && os(iOS)
import Foundation
import Network
import Security
import SwiftMail

nonisolated enum DevMailProbeOutcome: Equatable, Sendable {
    case passed(String)
    case notRun(String)
    case failed(String)
}

nonisolated enum DevMailProbeStage: String, CaseIterable, Sendable {
    case dns = "DNS"
    case tcp = "TCP"
    case tls = "TLS"
    case connect = "CONNECT"
    case auth = "AUTH"
}

nonisolated struct DevMailProbeStep: Equatable, Sendable {
    let stage: DevMailProbeStage
    let outcome: DevMailProbeOutcome
    let milliseconds: Int?

    var line: String {
        let status: String
        let detail: String
        switch outcome {
        case .passed(let text): status = "ok"; detail = text
        case .notRun(let text): status = "not run"; detail = text
        case .failed(let text): status = "FAILED"; detail = text
        }
        let timing = milliseconds.map { " [\($0) ms]" } ?? ""
        return "  " + stage.rawValue.padded(to: 9) + status.padded(to: 8) + detail + timing
    }
}

nonisolated struct DevMailProbeReport: Equatable, Sendable {
    let service: DevMailProbeService
    let host: String
    let port: Int
    let scheme: MailTransportScheme
    let steps: [DevMailProbeStep]

    var text: String {
        (["\(service.rawValue) \(host):\(port) · \(scheme.title)"] + steps.map(\.line)).joined(separator: "\n")
    }
}

nonisolated enum DevMailProbeService: String, CaseIterable, Sendable {
    case imap = "IMAP"
    case smtp = "SMTP"
}

nonisolated enum DevMailProbeCredentials: Equatable, Sendable {
    case use(username: String, password: String)
    case unavailable(String)
}

nonisolated enum DevMailConnectionProbe {
    static let stageTimeout: Duration = .seconds(10)

    private static let queue = DispatchQueue(label: "org.ntust.app.TigerDuck.DevMailConnectionProbe")

    static func refusal(for draft: MailServerOverrideSettings) -> String? {
        guard draft.isEnabled else {
            return """
            The override is off, so there is nothing here to test but the school server, and this \
            button never connects to that. Turn the override on and fill in a server first.
            """
        }
        guard let settings = draft.normalized else {
            return """
            Incomplete. This needs an address domain, an IMAP host, an SMTP host and two ports in \
            1–65535 before there is anything to connect to.
            """
        }
        let school = [settings.imapHost, settings.smtpHost].filter(isSchoolHost)
        guard school.isEmpty else {
            return """
            \(Array(Set(school)).sorted().joined(separator: ", ")) is an NTUST host, and this \
            button never tests the school server: it would put the real mail password through a \
            diagnostic connection, and the school path is not what this screen is for.
            """
        }
        return nil
    }

    static func isSchoolHost(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty else { return false }
        if host == MailServerConfig.school.imapHost || host == MailServerConfig.school.smtpHost { return true }
        return MailServerConfig.isPinnedHost(host)
    }

    static func credentials(
        username: String?,
        password: String?,
        appliedIsOverridden: Bool
    ) -> DevMailProbeCredentials {
        let username = (username ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let password = password ?? ""
        guard !username.isEmpty, !password.isEmpty else {
            return .unavailable("no saved credentials, so this was connect-and-handshake only")
        }
        guard appliedIsOverridden else {
            return .unavailable("""
            the saved password belongs to the school account and is never sent anywhere else — \
            apply this override, sign in to the test account, then test again
            """)
        }
        return .use(username: username, password: password)
    }

    static func describeUsername(_ username: String) -> String {
        "username: \(username.count) characters, \(username.contains("@") ? "with" : "no") \"@\""
    }

    static func haltReason(_ steps: [DevMailProbeStep]) -> String? {
        for step in steps {
            if case .failed = step.outcome { return "\(step.stage.rawValue) failed" }
        }
        return nil
    }

    static func run(config: MailServerConfig, credentials: DevMailProbeCredentials) async -> [DevMailProbeReport] {
        var reports: [DevMailProbeReport] = []
        for service in DevMailProbeService.allCases {
            reports.append(await probe(service: service, config: config, credentials: credentials))
        }
        return reports
    }

    static func text(of reports: [DevMailProbeReport]) -> String {
        reports.map(\.text).joined(separator: "\n\n")
    }

    private static func probe(
        service: DevMailProbeService,
        config: MailServerConfig,
        credentials: DevMailProbeCredentials
    ) async -> DevMailProbeReport {
        let host = service == .imap ? config.imapHost : config.smtpHost
        let port = service == .imap ? config.imapPort : config.smtpPort
        let scheme = service == .imap ? config.imapScheme : config.smtpScheme

        var steps: [DevMailProbeStep] = []
        if shouldContinue(steps) {
            steps.append(await dnsStep(host: host, port: port))
        }
        if shouldContinue(steps) {
            steps.append(await transportStep(.tcp, host: host, port: port, scheme: scheme))
        }
        if shouldContinue(steps) {
            steps.append(await transportStep(.tls, host: host, port: port, scheme: scheme))
        }
        if shouldContinue(steps) {
            steps.append(contentsOf: await sessionSteps(
                service: service, host: host, port: port, scheme: scheme, credentials: credentials
            ))
        }
        return DevMailProbeReport(
            service: service, host: host, port: port, scheme: scheme, steps: filledOut(steps)
        )
    }

    private static func shouldContinue(_ steps: [DevMailProbeStep]) -> Bool {
        !Task.isCancelled && haltReason(steps) == nil
    }

    private static func filledOut(_ steps: [DevMailProbeStep]) -> [DevMailProbeStep] {
        let reason = haltReason(steps) ?? (Task.isCancelled ? "cancelled" : nil)
        guard let reason else { return steps }
        var steps = steps
        for stage in DevMailProbeStage.allCases where !steps.contains(where: { $0.stage == stage }) {
            steps.append(DevMailProbeStep(stage: stage, outcome: .notRun(reason), milliseconds: nil))
        }
        return steps
    }

    private static func dnsStep(host: String, port: Int) async -> DevMailProbeStep {
        let start = ContinuousClock.now
        let resolution = await withTimeout(stageTimeout) { await resolveOffThread(host: host, port: port) }
        let outcome: DevMailProbeOutcome
        switch resolution {
        case .some(.addresses(let addresses)) where !addresses.isEmpty:
            outcome = .passed(addresses.joined(separator: ", "))
        case .some(.addresses):
            outcome = .failed("getaddrinfo() succeeded but returned no address")
        case .some(.failed(let code)):
            outcome = .failed("getaddrinfo() = \(code) (\(String(cString: gai_strerror(code))))")
        case nil:
            outcome = .failed("timed out after \(stageTimeout) — the resolver never answered")
        }
        return DevMailProbeStep(stage: .dns, outcome: outcome, milliseconds: milliseconds(since: start))
    }

    private enum Resolution: Sendable {
        case addresses([String])
        case failed(Int32)
    }

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

    private static func transportStep(
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
            outcome = .failed(describe(error))
        case nil:
            outcome = .failed(
                stage == .tls
                    ? "timed out after \(stageTimeout) — the handshake never completed"
                    : "timed out after \(stageTimeout) — no answer, which is what a filtered port looks like"
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
        let result = await withTimeout(stageTimeout) { await connection.wait(on: queue) }
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
                        resumer.resume(.ready(DevMailConnectionProbe.describe(ready: connection)))
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
            parts.append(tlsVersionName(version.rawValue))
        }
        return parts.isEmpty ? "connected" : parts.joined(separator: ", ")
    }

    static func tlsVersionName(_ rawVersion: UInt16) -> String {
        switch rawVersion {
        case 0x0301: "TLS 1.0"
        case 0x0302: "TLS 1.1"
        case 0x0303: "TLS 1.2"
        case 0x0304: "TLS 1.3"
        case 0xfeff: "DTLS 1.0"
        case 0xfefd: "DTLS 1.2"
        default: "TLS 0x\(String(rawVersion, radix: 16))"
        }
    }

    private static func sessionSteps(
        service: DevMailProbeService,
        host: String,
        port: Int,
        scheme: MailTransportScheme,
        credentials: DevMailProbeCredentials
    ) async -> [DevMailProbeStep] {
        switch service {
        case .imap:
            let server = IMAPServer(
                host: host,
                port: port,
                transportSecurity: scheme.swiftMailTransportSecurity,
                certificateVerificationPolicy: .custom(MailTLSVerifier.swiftMailVerifier),
                minimumTLSVersion: .tlsv12
            )
            return await session(
                credentials: credentials,
                connect: { try await server.connect() },
                login: { try await server.login(username: $0, password: $1) },
                close: { loggedIn in
                    if loggedIn { try? await server.logout() }
                    try? await server.disconnect()
                }
            )
        case .smtp:
            let server = SMTPServer(
                host: host,
                port: port,
                transportSecurity: scheme.swiftMailTransportSecurity,
                certificateVerificationPolicy: .custom(MailTLSVerifier.swiftMailVerifier),
                minimumTLSVersion: .tlsv12
            )
            return await session(
                credentials: credentials,
                connect: { try await server.connect() },
                login: { try await server.login(username: $0, password: $1) },
                close: { _ in try? await server.disconnect() }
            )
        }
    }

    private static func session(
        credentials: DevMailProbeCredentials,
        connect: @escaping @Sendable () async throws -> Void,
        login: @escaping @Sendable (String, String) async throws -> Void,
        close: @escaping @Sendable (Bool) async -> Void
    ) async -> [DevMailProbeStep] {
        var steps: [DevMailProbeStep] = []
        let connectStart = ContinuousClock.now
        let connected = await withTimeout(stageTimeout) { () -> StepResult in
            do {
                try await connect()
                return .ok("the server answered and the session is open")
            } catch {
                return .failed(describe(error))
            }
        }
        steps.append(step(
            .connect, connected, since: connectStart,
            timedOut: "the socket opened but no greeting or handshake finished"
        ))

        var loggedIn = false
        if haltReason(steps) != nil {
            steps.append(DevMailProbeStep(stage: .auth, outcome: .notRun("CONNECT failed"), milliseconds: nil))
        } else {
            switch credentials {
            case .unavailable(let reason):
                steps.append(DevMailProbeStep(stage: .auth, outcome: .notRun(reason), milliseconds: nil))
            case .use(let username, let password):
                let authStart = ContinuousClock.now
                let result = await withTimeout(stageTimeout) { () -> StepResult in
                    do {
                        try await login(username, password)
                        return .ok("accepted — \(describeUsername(username))")
                    } catch {
                        return .failed(describe(error))
                    }
                }
                if case .some(.ok) = result { loggedIn = true }
                steps.append(step(
                    .auth, result, since: authStart,
                    timedOut: "the credentials went out and the server never answered"
                ))
            }
        }

        let didLogIn = loggedIn
        _ = await withTimeout(stageTimeout) { () -> StepResult in
            await close(didLogIn)
            return .ok("")
        }
        return steps
    }

    private enum StepResult: Sendable {
        case ok(String)
        case failed(String)
    }

    private static func step(
        _ stage: DevMailProbeStage,
        _ result: StepResult?,
        since start: ContinuousClock.Instant,
        timedOut: String
    ) -> DevMailProbeStep {
        let elapsed = milliseconds(since: start)
        switch result {
        case .some(.ok(let detail)):
            return DevMailProbeStep(stage: stage, outcome: .passed(detail), milliseconds: elapsed)
        case .some(.failed(let detail)):
            return DevMailProbeStep(stage: stage, outcome: .failed(detail), milliseconds: elapsed)
        case nil:
            return DevMailProbeStep(
                stage: stage,
                outcome: .failed("timed out after \(stageTimeout) — \(timedOut)"),
                milliseconds: elapsed
            )
        }
    }

    static func describe(_ error: any Error) -> String {
        if let network = error as? NWError { return describe(network) }
        let bridged = error as NSError
        let described = "\(type(of: error)): \(String(describing: error))"
        guard carriesReadableCode(domain: bridged.domain) else { return described }
        return "\(described) [\(bridged.domain) \(bridged.code)]"
    }

    static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            return "NWError.posix(\(code)) — errno \(code.rawValue), \(String(cString: strerror(code.rawValue)))"
        case .dns(let code):
            return "NWError.dns(\(code)) — \(dnsErrorName(code))"
        case .tls(let status):
            return "NWError.tls(\(status)) — \(securityMessage(status))"
        default:
            return String(describing: error)
        }
    }

    static func carriesReadableCode(domain: String) -> Bool {
        [NSURLErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain, "kCFErrorDomainCFNetwork"].contains(domain)
    }

    static func dnsErrorName(_ code: DNSServiceErrorType) -> String {
        switch code {
        case -65537: "kDNSServiceErr_Unknown"
        case -65538: "kDNSServiceErr_NoSuchName"
        case -65540: "kDNSServiceErr_BadParam"
        case -65544: "kDNSServiceErr_Unsupported"
        case -65553: "kDNSServiceErr_Refused"
        case -65554: "kDNSServiceErr_NoSuchRecord — the name exists but has no address record"
        case -65562: "kDNSServiceErr_Transient"
        case -65563: "kDNSServiceErr_ServiceNotRunning"
        case -65566: "kDNSServiceErr_NoRouter"
        case -65568: "kDNSServiceErr_Timeout"
        default: "unnamed DNSServiceErrorType"
        }
    }

    static func securityMessage(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "no message for this OSStatus"
    }

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

    private final class OneShotResumer<T: Sendable>: @unchecked Sendable {
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

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = (ContinuousClock.now - start).components
        return Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
    }
}

nonisolated private extension String {
    func padded(to width: Int) -> String {
        count >= width ? self + " " : self + String(repeating: " ", count: width - count)
    }
}
#endif
