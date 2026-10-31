#if os(iOS)
import Foundation
import SwiftMail
import Testing
@testable import TigerDuck

struct LiveMailClientTests {
    @Test(arguments: [
        ("NIOSSLError.handshakeFailed(... CERTIFICATE_VERIFY_FAILED)", MailClientError.certificateRejected),
        ("NO [UNAVAILABLE] Too many connections", .serverBusy),
        ("server busy, try again later", .serverBusy),
        ("NO [AUTHENTICATIONFAILED] Invalid credentials", .authenticationFailed),
        ("connection reset by peer", .unreachable),
        ("NIOSSLError.handshakeFailed(... PROTOCOL_VERSION alert)", .unreachable),
    ])
    func classifiesServerText(text: String, expected: MailClientError) {
        #expect(MailIMAPErrors.classify(text, fallback: .unreachable) == expected)
    }

    @Test func passesMailErrorsThrough() {
        #expect(MailIMAPErrors.map(MailClientError.searchUnsupported) == .searchUnsupported)
    }

    @Test func networkShapedErrorsCountAsUnreachable() {
        #expect(MailIMAPErrors.map(URLError(.timedOut)) == .unreachable)
        #expect(MailIMAPErrors.map(NSError(domain: NSPOSIXErrorDomain, code: 61)) == .unreachable)
    }

    @Test func unknownErrorsThatAreNotNetworkShapedCountAsProtocolErrors() {
        struct SomethingElse: Error {}
        let error = SomethingElse()
        #expect(MailIMAPErrors.map(error) == .protocolError(String(describing: error)))
    }

    @Test func decoderAndParserFailuresCountAsProtocolErrors() {
        struct StandInParserError: Error {}
        // Named-matched the way SwiftMail's own connection recycling recognizes these, since the
        // real `IMAPDecoderError` type is not re-exported. `MailFetchSectionTests` runs the real
        // one, produced by NIOIMAP's own pipeline from the bytes Mail2000 sent.
        #expect(MailIMAPErrors.isDecodeFailure(StandInParserError()))
        #expect(!MailIMAPErrors.isDecodeFailure(URLError(.timedOut)))
    }

    @Test func mapsSMTPSendErrorsToProtocolErrorCarryingTheDescription() {
        let sendError = SMTPSendError(phase: .data, acceptance: .notAccepted, reason: .connectionLost)
        #expect(MailIMAPErrors.map(sendError) == .protocolError(String(describing: sendError)))
    }

    @Test func mapsRefusedSearchCommandsToSearchUnsupported() {
        #expect(MailIMAPErrors.mapSearchError(.commandFailed("NO search not allowed")) == .searchUnsupported)
        #expect(MailIMAPErrors.mapSearchError(.commandNotSupported("SEARCH not supported")) == .searchUnsupported)
    }

    @Test func nonSearchIMAPErrorsFallThroughToTheGeneralMapping() {
        #expect(MailIMAPErrors.mapSearchError(.timeout) == .unreachable)
        #expect(MailIMAPErrors.mapSearchError(.loginFailed("NO")) == .authenticationFailed)
    }

    @Test func onlyNetworkAndCertificateFailuresCloseTheConnection() {
        #expect(MailErrorClass(MailClientError.unreachable).closesConnection)
        #expect(MailErrorClass(MailClientError.certificateRejected).closesConnection)
        #expect(!MailErrorClass(MailClientError.authenticationFailed).closesConnection)
        #expect(!MailErrorClass(MailClientError.serverBusy).closesConnection)
        #expect(!MailErrorClass(MailClientError.searchUnsupported).closesConnection)
        #expect(!MailErrorClass(MailClientError.folderChanged).closesConnection)
        #expect(!MailErrorClass(MailClientError.protocolError("x")).closesConnection)
    }

    @Test func uidValidityChangeDetection() throws {
        #expect(!MailIMAPFetch.uidValidityChanged(expected: nil, current: 5))
        #expect(!MailIMAPFetch.uidValidityChanged(expected: 5, current: 5))
        #expect(MailIMAPFetch.uidValidityChanged(expected: 5, current: 6))
        try MailIMAPFetch.assertUIDValidity(expected: nil, current: 5)
        try MailIMAPFetch.assertUIDValidity(expected: 5, current: 5)
        #expect(throws: MailClientError.folderChanged) {
            try MailIMAPFetch.assertUIDValidity(expected: 5, current: 6)
        }
    }

    @Test(arguments: [
        ("NO [UNAVAILABLE] Try again later", MailClientError.serverBusy),
        ("NO [LIMIT] Too many simultaneous logins", .serverBusy),
        ("NO [INUSE] Mailbox in use by another session", .serverBusy),
        ("NO Too many connections, try again later", .serverBusy),
        ("NO TOO MANY CONNECTIONS", .serverBusy),
        ("NO Invalid credentials", .authenticationFailed),
        ("NO Authentication failed, please try again", .authenticationFailed),
    ])
    func classifiesLoginFailures(text: String, expected: MailClientError) {
        #expect(MailIMAPErrors.classifyLoginFailure(text) == expected)
    }

    @Test func swiftMailDecodesHeadersWithTheA5Rules() {
        SchoolMailCharsetHook.install()
        let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        let bytes = "中文".data(using: big5)! + Data([0x88, 0x40])
        let decoded = SchoolMailCharsetHook.decodeHeader("=?big5?B?\(bytes.base64EncodedString())?=")
        #expect(decoded.hasPrefix("中文"))
        #expect(decoded.count == 3)
    }
}
#endif
