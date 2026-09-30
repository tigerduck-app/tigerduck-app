#if DEBUG && os(iOS)
import Foundation
import Network
import Security
import SwiftMail

/// One stage of a connection attempt, and what happened in it.
nonisolated enum DevMailProbeOutcome: Equatable, Sendable {
    /// The stage completed. The text is what it found — the addresses a name resolved to, the
    /// negotiated TLS version, the fact that the server accepted the credentials.
    case passed(String)
    /// The stage was not run, and why: an earlier one failed, the transport makes it meaningless,
    /// or there is nothing to authenticate with.
    case notRun(String)
    /// The stage failed. The text is the **underlying** error — the `NWError` case with its POSIX
    /// errno, DNS code or TLS `OSStatus`, or the SwiftMail error as it was thrown. Never a
    /// friendly summary: five sentences that cover every failure are what this screen exists to
    /// get behind.
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
    /// How long the stage took. Nil for a stage that never ran — "0 ms" would read as a result.
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

/// One endpoint's result: what was tried, against what, and how far it got.
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

/// What the probe may sign in with, or why it will not try.
nonisolated enum DevMailProbeCredentials: Equatable, Sendable {
    case use(username: String, password: String)
    case unavailable(String)
}

/// The Test connection diagnostic behind `Settings → Developer → Email`.
///
/// It exists because the app's own error reporting cannot answer the question a developer
/// pointing School Mail at their own server actually has. `MailClientError` has five cases and
/// `MailAccountManager.LoginError` turns those into five sentences, so a name that does not
/// resolve, a port nothing is listening on, a port a firewall is dropping, a TLS handshake the
/// system will not trust and a password the server rejected all arrive on screen as
/// "Can't reach the mail server". **Nothing here goes through that classification.** Every failure
/// is reported as the error that was actually thrown.
///
/// The run is staged, and each stage answers exactly one question:
///
/// - `DNS` — does the name resolve, and to what? Run with `getaddrinfo`, so the addresses
///   themselves are on screen: "it resolves but nothing answers" is the shape of the case this
///   was written for, and it is only visible if the resolution is a step of its own.
/// - `TCP` — does anything accept a connection there? A plain `NWConnection`, so a refusal is
///   `ECONNREFUSED` and a filtered port is a timeout rather than both being "unreachable".
/// - `TLS` — does a handshake complete under ordinary system trust? Also `NWConnection`, which
///   surfaces a trust failure as an `OSStatus` the system can name. Implicit TLS only; STARTTLS
///   is negotiated inside the protocol, so for that the `CONNECT` stage below is the handshake.
/// - `CONNECT` — the same thing again through **the app's own path**: SwiftMail, with
///   `MailTLSVerifier` installed exactly as `LiveMailClient` installs it. A server the system
///   trusts but this client does not fails here and nowhere else.
/// - `AUTH` — IMAP `LOGIN` / SMTP `AUTH`, when there are credentials that may be sent.
///
/// Two things it will not do. It never connects to the school server (`refusal(for:)`), and it
/// never sends the school account's password to a server that is not the school's
/// (`credentials(username:password:appliedIsOverridden:)`). It also never touches
/// `MailAccountManager`, the cache or the credential store: everything below builds its own
/// connections, uses them and closes them.
nonisolated enum DevMailConnectionProbe {
    /// How long any one stage may take before it is reported as a hang. A filtered port is the
    /// case this bounds: left alone, the socket sits there for a minute or more, and "it hung" is
    /// the diagnosis rather than something to keep waiting for.
    static let stageTimeout: Duration = .seconds(10)

    private static let queue = DispatchQueue(label: "org.ntust.app.TigerDuck.DevMailConnectionProbe")

    // MARK: What may be tested, and with what

    /// Why this draft must not be tested, or nil when it may be.
    ///
    /// The draft, deliberately — the point is to diagnose a server *before* applying it, since
    /// applying signs the account out.
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

    /// Whether a host is the school's. Both the configured school host and the pin table are
    /// consulted — the table is what `MailServerConfig.transportScheme(for:requested:)` already
    /// clamps against, so a host it knows is one this app treats as NTUST's however the screen
    /// spells it.
    static func isSchoolHost(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty else { return false }
        if host == MailServerConfig.school.imapHost || host == MailServerConfig.school.smtpHost { return true }
        return MailServerConfig.isPinnedHost(host)
    }

    /// Whether the saved password may be sent to the server under test.
    ///
    /// Testing without one is a first-class case: the probe connects and hands shakes and reports
    /// that authentication was not attempted. That is also the common case, because a sign-in that
    /// failed never saved a password — `MailAccountManager.login` stores it only after the server
    /// has accepted it — so the developer whose server will not connect has nothing saved for it.
    ///
    /// `appliedIsOverridden` is the safety rule, and it is the same rule as refusing to test the
    /// school host, pointed the other way: while the *applied* configuration is still the school's,
    /// the saved password is the school account's, and a diagnostic must not send it to somebody
    /// else's server. Apply the override, sign in to the test account, and it becomes testable.
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

    /// What can be said about a username without putting it on a screen that will be screenshotted
    /// or pasted into a bug report. The length, and whether it carries a domain — which is the part
    /// that matters, since a third-party server usually wants the full address as the username and
    /// the school's never does.
    static func describeUsername(_ username: String) -> String {
        "username: \(username.count) characters, \(username.contains("@") ? "with" : "no") \"@\""
    }

    /// The reason the stages after the ones already run are not worth running, or nil to carry on.
    /// A failed stage stops that endpoint: everything below it fails for the same reason and says
    /// nothing new.
    static func haltReason(_ steps: [DevMailProbeStep]) -> String? {
        for step in steps {
            if case .failed = step.outcome { return "\(step.stage.rawValue) failed" }
        }
        return nil
    }

    // MARK: Running

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

    /// Every stage appears in the report, including the ones that were never reached — a stage
    /// missing from the output would read as a stage that passed.
    private static func filledOut(_ steps: [DevMailProbeStep]) -> [DevMailProbeStep] {
        // A failure that already happened is the better answer: a run cancelled *after* something
        // failed should still say what failed.
        let reason = haltReason(steps) ?? (Task.isCancelled ? "cancelled" : nil)
        guard let reason else { return steps }
        var steps = steps
        for stage in DevMailProbeStage.allCases where !steps.contains(where: { $0.stage == stage }) {
            steps.append(DevMailProbeStep(stage: stage, outcome: .notRun(reason), milliseconds: nil))
        }
        return steps
    }

    // MARK: DNS

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

    // MARK: TCP and TLS

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
            // The same floor `LiveMailClient` gives SwiftMail, so a server that only offers
            // something older fails here the way it would fail there.
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

    /// The connection, held somewhere it can be closed whatever the race between the handshake and
    /// the timeout did — including when the timeout won and nothing else will ever touch it.
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
            parts.append(tlsVersionName(version.rawValue))
        }
        return parts.isEmpty ? "connected" : parts.joined(separator: ", ")
    }

    /// The negotiated version, by its wire number rather than by `tls_protocol_version_t`'s cases:
    /// the two cases worth *reporting* most loudly — 1.0 and 1.1 — are the two the SDK deprecates
    /// naming, and a diagnostic that cannot say "this server negotiated TLS 1.0" is no use. The
    /// numbers are the TLS `ProtocolVersion` values themselves and do not move.
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

    // MARK: The app's own client path

    /// `CONNECT` and `AUTH`, through SwiftMail with `MailTLSVerifier` installed exactly as
    /// `LiveMailClient` installs it — the same transport mapping, the same custom verification
    /// policy, the same TLS floor.
    ///
    /// Built here rather than borrowed from `LiveMailClient` for one reason: that type maps every
    /// error it throws through `MailClientError`, which is the classification this whole feature
    /// exists to get behind. Its SMTP side is also only reachable by actually sending a message.
    /// The connections below are this probe's own, are used once, and are closed before it returns.
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

        // Closing is bounded too: a server that accepted the credentials and then stopped
        // answering must not leave this screen spinning on a LOGOUT.
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

    // MARK: Describing errors

    /// An error as close to the wire as one line can put it.
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
        // Plain `default`, not `@unknown default`: `NWError` keeps gaining cases (`.wifiAware`
        // is one), and a case this probe has no special reading of is still best reported as
        // whatever Network calls it.
        default:
            return String(describing: error)
        }
    }

    /// Whether an `NSError` domain carries a code worth printing beside the error itself. A Swift
    /// enum bridges to a domain that is its own mangled type name and a code that is its case
    /// index, which says nothing the description does not.
    static func carriesReadableCode(domain: String) -> Bool {
        [NSURLErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain, "kCFErrorDomainCFNetwork"].contains(domain)
    }

    /// `<dns_sd.h>`'s `kDNSServiceErr_*` values, for the ones a mail host actually produces.
    /// Hard-coded rather than imported so this stays a plain value mapping a test can pin.
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

    // MARK: Timing out

    /// Runs `work`, answering nil when it has not finished within `timeout`.
    ///
    /// Not a task group: a group does not return until every child has finished, and not waiting
    /// for work that has not finished is the whole point here. SwiftMail's IMAP and SMTP commands
    /// ignore task cancellation, and a filtered port is exactly the case where a socket sits for a
    /// minute or more — so the unfinished work is left to end on its own, with nobody reading it,
    /// while the stage reports the hang. Every connection this probe opens is held by its caller
    /// and closed regardless of which side of the race won.
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

    /// A continuation two racing callers may both try to resume, and exactly one does.
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

/// `nonisolated` explicitly: this target's default actor isolation is `MainActor`, and the report
/// is built off the main actor.
nonisolated private extension String {
    /// Column padding for the report, which is read in a monospaced font. Never truncates: a stage
    /// name is worth more than the alignment of the line it is on.
    func padded(to width: Int) -> String {
        count >= width ? self + " " : self + String(repeating: " ", count: width - count)
    }
}
#endif
