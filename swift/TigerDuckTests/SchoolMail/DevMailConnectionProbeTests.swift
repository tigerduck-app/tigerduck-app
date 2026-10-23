#if DEBUG && os(iOS)
import Foundation
import Network
import Testing
@testable import TigerDuck

@MainActor
struct DevMailConnectionProbeTests {
    static func settings(
        enabled: Bool = true,
        domain: String = "example.com",
        imapHost: String = "imap.example.com",
        imapPort: Int = 993,
        smtpHost: String = "smtp.example.com",
        smtpPort: Int = 465
    ) -> MailServerOverrideSettings {
        MailServerOverrideSettings(
            isEnabled: enabled,
            addressDomain: domain,
            imapHost: imapHost,
            imapPort: imapPort,
            imapScheme: .implicitTLS,
            smtpHost: smtpHost,
            smtpPort: smtpPort,
            smtpScheme: .implicitTLS
        )
    }

    @Test func aThirdPartyDraftIsTestable() {
        #expect(DevMailConnectionProbe.refusal(for: Self.settings()) == nil)
    }

    @Test func anOverrideThatIsOffIsRefused() {
        let refusal = DevMailConnectionProbe.refusal(for: Self.settings(enabled: false))
        #expect(refusal?.contains("override is off") == true)
    }

    @Test func anIncompleteDraftIsRefusedBeforeAnySocket() {
        #expect(DevMailConnectionProbe.refusal(for: Self.settings(imapHost: " "))?.contains("Incomplete") == true)
        #expect(DevMailConnectionProbe.refusal(for: Self.settings(domain: ""))?.contains("Incomplete") == true)
        #expect(DevMailConnectionProbe.refusal(for: Self.settings(smtpPort: 0))?.contains("Incomplete") == true)
    }

    @Test func theSchoolServerIsNeverTested() {
        let asIMAP = DevMailConnectionProbe.refusal(for: Self.settings(imapHost: "mail.ntust.edu.tw"))
        #expect(asIMAP?.contains("mail.ntust.edu.tw") == true)
        #expect(asIMAP?.contains("NTUST host") == true)

        let asSMTP = DevMailConnectionProbe.refusal(for: Self.settings(smtpHost: "MAIL.NTUST.EDU.TW"))
        #expect(asSMTP?.contains("mail.ntust.edu.tw") == true)
    }

    @Test func anyPinnedNTUSTHostIsRefused() {
        #expect(DevMailConnectionProbe.isSchoolHost("mail.ntust.edu.tw"))
        #expect(DevMailConnectionProbe.isSchoolHost("imap.ntust.edu.tw"))
        #expect(DevMailConnectionProbe.isSchoolHost("  Mail.NTUST.edu.tw "))
        #expect(!DevMailConnectionProbe.isSchoolHost("imap.example.com"))
        #expect(!DevMailConnectionProbe.isSchoolHost(""))
        #expect(DevMailConnectionProbe.refusal(for: Self.settings(imapHost: "imap.ntust.edu.tw")) != nil)
    }

    @Test func savedCredentialsAreUsedWhenTheOverrideIsTheOneInForce() {
        let decision = DevMailConnectionProbe.credentials(
            username: " tester@example.com ", password: "not-a-real-password", appliedIsOverridden: true
        )
        #expect(decision == .use(username: "tester@example.com", password: "not-a-real-password"))
    }

    @Test func noSavedPasswordStillTestsTheConnection() {
        let missingPassword = DevMailConnectionProbe.credentials(
            username: "tester@example.com", password: nil, appliedIsOverridden: true
        )
        #expect(missingPassword == .unavailable("no saved credentials, so this was connect-and-handshake only"))

        let missingUsername = DevMailConnectionProbe.credentials(
            username: "   ", password: "not-a-real-password", appliedIsOverridden: true
        )
        #expect(missingUsername == .unavailable("no saved credentials, so this was connect-and-handshake only"))
    }

    @Test func theSchoolAccountsPasswordIsNeverSentToAnotherServer() {
        let decision = DevMailConnectionProbe.credentials(
            username: "b10000000", password: "not-a-real-password", appliedIsOverridden: false
        )
        guard case .unavailable(let reason) = decision else {
            Issue.record("the school account's password must not be offered to a test server")
            return
        }
        #expect(reason.contains("school account"))
    }

    @Test func theUsernameIsDescribedRatherThanPrinted() {
        let described = DevMailConnectionProbe.describeUsername("tester@example.com")
        #expect(!described.contains("tester"))
        #expect(described.contains("18 characters"))
        #expect(described.contains("with \"@\""))
        #expect(DevMailConnectionProbe.describeUsername("b10000000").contains("no \"@\""))
    }

    @Test func aFailedStageStopsTheOnesBelowIt() {
        #expect(DevMailConnectionProbe.haltReason([]) == nil)
        #expect(DevMailConnectionProbe.haltReason([
            DevMailProbeStep(stage: .dns, outcome: .passed("203.0.113.7"), milliseconds: 4),
            DevMailProbeStep(stage: .tls, outcome: .notRun("STARTTLS negotiates inside the protocol"), milliseconds: nil),
        ]) == nil)
        #expect(DevMailConnectionProbe.haltReason([
            DevMailProbeStep(stage: .dns, outcome: .passed("203.0.113.7"), milliseconds: 4),
            DevMailProbeStep(stage: .tcp, outcome: .failed("NWError.posix(ECONNREFUSED)"), milliseconds: 12),
        ]) == "TCP failed")
    }

    @Test func eachTransportFailureIsWrittenDownAsItself() {
        let refused = DevMailConnectionProbe.describe(NWError.posix(.ECONNREFUSED))
        #expect(refused.contains("NWError.posix"))
        #expect(refused.contains("errno 61"))
        #expect(refused.lowercased().contains("connection refused"))

        let timedOut = DevMailConnectionProbe.describe(NWError.posix(.ETIMEDOUT))
        #expect(timedOut.contains("errno 60"))

        let noSuchRecord = DevMailConnectionProbe.describe(NWError.dns(-65554))
        #expect(noSuchRecord.contains("NWError.dns(-65554)"))
        #expect(noSuchRecord.contains("kDNSServiceErr_NoSuchRecord"))

        // errSSLXCertChainInvalid — the shape a third-party certificate the system will not build
        // a chain for arrives in.
        let badChain = DevMailConnectionProbe.describe(NWError.tls(-9807))
        #expect(badChain.contains("NWError.tls(-9807)"))
    }

    @Test func anUnnamedDNSCodeStillReportsItsNumber() {
        #expect(DevMailConnectionProbe.dnsErrorName(-65538) == "kDNSServiceErr_NoSuchName")
        #expect(DevMailConnectionProbe.dnsErrorName(-1) == "unnamed DNSServiceErrorType")
        #expect(DevMailConnectionProbe.describe(NWError.dns(-1)).contains("-1"))
    }

    /// A SwiftMail error reaches the report as the case that was thrown, with its payload — which
    /// for a rejected LOGIN is the server's own reply text, the one thing
    /// `MailClientError.authenticationFailed` throws away.
    @Test func aThrownErrorKeepsItsTypeAndPayload() {
        let described = DevMailConnectionProbe.describe(SampleMailError.loginFailed("NO invalid credentials"))
        #expect(described.hasPrefix("SampleMailError:"))
        #expect(described.contains("NO invalid credentials"))
        // A Swift enum bridges to an NSError whose domain is its own mangled name and whose code
        // is its case index; neither says anything, so neither is printed.
        #expect(!described.contains("["))
    }

    @Test func aFoundationErrorKeepsItsDomainAndCode() {
        let described = DevMailConnectionProbe.describe(NSError(domain: NSURLErrorDomain, code: -1004))
        #expect(described.contains("[\(NSURLErrorDomain) -1004]"))
        #expect(DevMailConnectionProbe.carriesReadableCode(domain: NSPOSIXErrorDomain))
        #expect(DevMailConnectionProbe.carriesReadableCode(domain: "kCFErrorDomainCFNetwork"))
        #expect(!DevMailConnectionProbe.carriesReadableCode(domain: "TigerDuck.SomeSwiftError"))
    }

    /// Named by wire number, so the versions worth reporting loudest — the old ones, which the SDK
    /// deprecates naming — can still be reported at all.
    @Test func aNegotiatedTLSVersionIsNamed() {
        #expect(DevMailConnectionProbe.tlsVersionName(0x0303) == "TLS 1.2")
        #expect(DevMailConnectionProbe.tlsVersionName(0x0304) == "TLS 1.3")
        #expect(DevMailConnectionProbe.tlsVersionName(0x0301) == "TLS 1.0")
        #expect(DevMailConnectionProbe.tlsVersionName(0x0099) == "TLS 0x99")
    }

    @Test func theReportIsOneCopyableBlockWithEveryStageInIt() {
        let report = DevMailProbeReport(
            service: .imap,
            host: "imap.example.com",
            port: 993,
            scheme: .implicitTLS,
            steps: [
                DevMailProbeStep(stage: .dns, outcome: .passed("203.0.113.7"), milliseconds: 12),
                DevMailProbeStep(stage: .tcp, outcome: .failed("NWError.posix(ECONNREFUSED)"), milliseconds: 8),
                DevMailProbeStep(stage: .tls, outcome: .notRun("TCP failed"), milliseconds: nil),
                DevMailProbeStep(stage: .connect, outcome: .notRun("TCP failed"), milliseconds: nil),
                DevMailProbeStep(stage: .auth, outcome: .notRun("TCP failed"), milliseconds: nil),
            ]
        )
        let lines = report.text.components(separatedBy: "\n")
        #expect(lines.count == 6)
        #expect(lines[0] == "IMAP imap.example.com:993 · Implicit TLS")
        #expect(lines[1] == "  DNS      ok      203.0.113.7 [12 ms]")
        #expect(lines[2] == "  TCP      FAILED  NWError.posix(ECONNREFUSED) [8 ms]")
        #expect(lines[3] == "  TLS      not run TCP failed")
        for stage in DevMailProbeStage.allCases {
            #expect(report.text.contains(stage.rawValue))
        }
    }

    @Test func bothEndpointsAreReportedSeparately() {
        let steps = [DevMailProbeStep(stage: .dns, outcome: .passed("203.0.113.7"), milliseconds: 1)]
        let text = DevMailConnectionProbe.text(of: [
            DevMailProbeReport(service: .imap, host: "imap.example.com", port: 993, scheme: .implicitTLS, steps: steps),
            DevMailProbeReport(service: .smtp, host: "smtp.example.com", port: 587, scheme: .startTLS, steps: steps),
        ])
        #expect(text.contains("IMAP imap.example.com:993 · Implicit TLS"))
        #expect(text.contains("SMTP smtp.example.com:587 · STARTTLS"))
        #expect(text.contains("\n\n"))
    }

    /// A filtered port answers nothing at all, and SwiftMail's own commands ignore task
    /// cancellation — so the timeout has to be able to return while the work is still running,
    /// rather than waiting for it the way a task group would.
    @Test func workThatDoesNotFinishInTimeAnswersNil() async {
        let answer = await DevMailConnectionProbe.withTimeout(.milliseconds(20)) {
            try? await Task.sleep(for: .seconds(30))
            return "finished"
        }
        #expect(answer == nil)
    }

    @Test func workThatFinishesInTimeAnswersItself() async {
        let answer = await DevMailConnectionProbe.withTimeout(.seconds(30)) { "finished" }
        #expect(answer == "finished")
    }

    private enum SampleMailError: Error {
        case loginFailed(String)
    }
}
#endif
