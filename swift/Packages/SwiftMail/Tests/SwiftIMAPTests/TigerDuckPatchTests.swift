import Foundation
import NIO
import NIOIMAPCore
import NIOSSL
import Testing
@testable import SwiftMail

// NIOIMAPCore and SwiftMail each declare a `UID` type; disambiguate the same way the
// rest of this test target does (see SearchCommandTests.swift).
private typealias UID = SwiftMail.UID

/// The three changes TigerDuck carries on top of 1.11.0.
@Suite("TigerDuck patches", .serialized, .timeLimit(.minutes(1)))
struct TigerDuckPatchTests {
    /// The public *.ntust.edu.tw leaf, so a real NIOSSLCertificate can be built.
    static let leafDERBase64 = "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"

    @Test("A custom policy keeps NIOSSL verification on so the callback runs")
    func customPolicyUsesFullVerification() {
        let verifier = MailCertificateVerifier(identifier: "test") { _, _ in true }
        let configuration = MailTLSConfiguration.makeClientConfiguration(
            certificateVerificationPolicy: .custom(verifier),
            minimumTLSVersion: .tlsv12
        )
        #expect(configuration.certificateVerification == .fullVerification)
    }

    @Test("Verifiers compare by identifier")
    func verifierEquality() {
        let a = MailCertificateVerifier(identifier: "pin") { _, _ in true }
        let b = MailCertificateVerifier(identifier: "pin") { _, _ in false }
        let c = MailCertificateVerifier(identifier: "other") { _, _ in true }
        #expect(MailCertificateVerificationPolicy.custom(a) == .custom(b))
        #expect(MailCertificateVerificationPolicy.custom(a) != .custom(c))
    }

    @Test("A custom policy builds a client handler")
    func customPolicyBuildsHandler() throws {
        let verifier = MailCertificateVerifier(identifier: "test") { _, _ in true }
        _ = try MailTLSConfiguration.makeClientHandler(
            host: "mail.ntust.edu.tw",
            certificateVerificationPolicy: .custom(verifier),
            minimumTLSVersion: .tlsv12
        )
    }

    @Test("The callback hands the verifier the DER chain and the host, and maps its answer")
    func callbackMapsVerdict() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let der = [UInt8](Data(base64Encoded: Self.leafDERBase64)!)
        let certificate = try NIOSSLCertificate(bytes: der, format: .der)
        let recorder = Recorder()

        for verdict in [true, false] {
            let verifier = MailCertificateVerifier(identifier: "test") { chain, host in
                recorder.record(chain: chain, host: host)
                return verdict
            }
            let callback = MailTLSConfiguration.customVerificationCallback(
                verifier: verifier, host: "mail.ntust.edu.tw"
            )
            let promise = group.next().makePromise(of: NIOSSLVerificationResult.self)
            callback([certificate], promise)
            let result = try promise.futureResult.wait()
            #expect(result == (verdict ? .certificateVerified : .failed))
        }
        #expect(recorder.chains == [[der], [der]])
        #expect(recorder.hosts == ["mail.ntust.edu.tw", "mail.ntust.edu.tw"])
    }

    @Test("Encoded words go through the installed charset resolver")
    func resolverOverridesIANA() {
        defer { MailCharsetResolver.setResolver(nil) }
        // "中文" in UTF-8. Mapping the made-up label to Latin-1 must change the result,
        // which proves the resolver (not the IANA table's UTF-8 fallback) was asked.
        MailCharsetResolver.setResolver { $0.lowercased() == "x-tigerduck" ? .isoLatin1 : nil }
        let expected = String(data: Data(base64Encoded: "5Lit5paH")!, encoding: .isoLatin1)
        #expect("=?x-tigerduck?B?5Lit5paH?=".decodeMIMEHeader() == expected)
    }

    @Test("Without an override the IANA table still decides")
    func resolverDefaultsToIANA() {
        MailCharsetResolver.setResolver(nil)
        #expect("=?utf-8?B?5Lit5paH?=".decodeMIMEHeader() == "中文")
    }

    @Test("Non-ASCII search text is sent with CHARSET UTF-8")
    func nonASCIISearchUsesUTF8() {
        let tagged = SearchCommand<UID>(criteria: [.subject("課程")]).toTaggedCommand(tag: "A1")
        guard case .uidSearch(_, let charset, _) = tagged.command else {
            Issue.record("expected UID SEARCH")
            return
        }
        #expect(charset == "UTF-8")
    }

    @Test("ASCII search text keeps the default charset")
    func asciiSearchOmitsCharset() {
        let tagged = SearchCommand<UID>(criteria: [.or(.from("moodle"), .subject("quiz"))]).toTaggedCommand(tag: "A1")
        guard case .uidSearch(_, let charset, _) = tagged.command else {
            Issue.record("expected UID SEARCH")
            return
        }
        #expect(charset == nil)
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var chains: [[[UInt8]]] = []
    private(set) var hosts: [String] = []

    func record(chain: [[UInt8]], host: String) {
        lock.withLock {
            chains.append(chain)
            hosts.append(host)
        }
    }
}
