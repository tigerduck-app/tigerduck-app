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
            steps.append(await DevMailNetworkProbe.dnsStep(host: host, port: port))
        }
        if shouldContinue(steps) {
            steps.append(await DevMailNetworkProbe.transportStep(.tcp, host: host, port: port, scheme: scheme))
        }
        if shouldContinue(steps) {
            steps.append(await DevMailNetworkProbe.transportStep(.tls, host: host, port: port, scheme: scheme))
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
        let connected = await DevMailNetworkProbe.withTimeout(stageTimeout) { () -> StepResult in
            do {
                try await connect()
                return .ok("the server answered and the session is open")
            } catch {
                return .failed(DevMailProbeErrors.describe(error))
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
                let result = await DevMailNetworkProbe.withTimeout(stageTimeout) { () -> StepResult in
                    do {
                        try await login(username, password)
                        return .ok("accepted — \(DevMailProbeDraft.describeUsername(username))")
                    } catch {
                        return .failed(DevMailProbeErrors.describe(error))
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
        _ = await DevMailNetworkProbe.withTimeout(stageTimeout) { () -> StepResult in
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
        let elapsed = DevMailNetworkProbe.milliseconds(since: start)
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

}

nonisolated private extension String {
    func padded(to width: Int) -> String {
        count >= width ? self + " " : self + String(repeating: " ", count: width - count)
    }
}
#endif
