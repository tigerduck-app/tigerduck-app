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
        // A handshake failure that doesn't mention a certificate (e.g. a protocol-version
        // alert) is a transport problem, not a trust one — it must not be misclassified as
        // certificateRejected just because the text contains "handshake".
        ("NIOSSLError.handshakeFailed(... PROTOCOL_VERSION alert)", .unreachable),
    ])
    func classifiesServerText(text: String, expected: MailClientError) {
        #expect(LiveMailClient.classify(text, fallback: .unreachable) == expected)
    }

    @Test func passesMailErrorsThrough() {
        #expect(LiveMailClient.map(MailClientError.searchUnsupported) == .searchUnsupported)
    }

    @Test func networkShapedErrorsCountAsUnreachable() {
        #expect(LiveMailClient.map(URLError(.timedOut)) == .unreachable)
        #expect(LiveMailClient.map(NSError(domain: NSPOSIXErrorDomain, code: 61)) == .unreachable)
    }

    /// `.unreachable` is not the fallback for an unrecognized error any more. It used to be, and
    /// that is how a FETCH response TigerDuck could not parse reached the user as
    /// 「無法連線到郵件伺服器」 on a device whose network was fine. An error that is neither
    /// recognized nor network-shaped says a protocol error went wrong, not the network.
    @Test func unknownErrorsThatAreNotNetworkShapedCountAsProtocolErrors() {
        struct SomethingElse: Error {}
        let error = SomethingElse()
        #expect(LiveMailClient.map(error) == .protocolError(String(describing: error)))
    }

    @Test func decoderAndParserFailuresCountAsProtocolErrors() {
        struct StandInParserError: Error {}
        // Named-matched the way SwiftMail's own connection recycling recognizes these, since the
        // real `IMAPDecoderError` type is not re-exported. `MailFetchSectionTests` runs the real
        // one, produced by NIOIMAP's own pipeline from the bytes Mail2000 sent.
        #expect(LiveMailClient.isDecodeFailure(StandInParserError()))
        #expect(!LiveMailClient.isDecodeFailure(URLError(.timedOut)))
    }

    @Test func mapsSMTPSendErrorsToProtocolErrorCarryingTheDescription() {
        let sendError = SMTPSendError(phase: .data, acceptance: .ambiguous, reason: .connectionLost)
        #expect(LiveMailClient.map(sendError) == .protocolError(String(describing: sendError)))
    }

    @Test func mapsRefusedSearchCommandsToSearchUnsupported() {
        #expect(LiveMailClient.mapSearchError(.commandFailed("NO search not allowed")) == .searchUnsupported)
        #expect(LiveMailClient.mapSearchError(.commandNotSupported("SEARCH not supported")) == .searchUnsupported)
    }

    @Test func nonSearchIMAPErrorsFallThroughToTheGeneralMapping() {
        #expect(LiveMailClient.mapSearchError(.timeout) == .unreachable)
        #expect(LiveMailClient.mapSearchError(.loginFailed("NO")) == .authenticationFailed)
    }

    @Test func onlyNetworkAndCertificateFailuresCloseTheConnection() {
        #expect(LiveMailClient.closesConnectionOnFailure(.unreachable))
        #expect(LiveMailClient.closesConnectionOnFailure(.certificateRejected))
        #expect(!LiveMailClient.closesConnectionOnFailure(.authenticationFailed))
        #expect(!LiveMailClient.closesConnectionOnFailure(.serverBusy))
        #expect(!LiveMailClient.closesConnectionOnFailure(.searchUnsupported))
        #expect(!LiveMailClient.closesConnectionOnFailure(.folderChanged))
        #expect(!LiveMailClient.closesConnectionOnFailure(.protocolError("x")))
    }

    @Test func uidValidityChangeDetection() throws {
        // No pin — only the read-flag callers, whose worst case is a flag on the wrong message.
        #expect(!LiveMailClient.uidValidityChanged(expected: nil, current: 5))
        #expect(!LiveMailClient.uidValidityChanged(expected: 5, current: 5))
        #expect(LiveMailClient.uidValidityChanged(expected: 5, current: 6))
        try LiveMailClient.assertUIDValidity(expected: nil, current: 5)
        try LiveMailClient.assertUIDValidity(expected: 5, current: 5)
        #expect(throws: MailClientError.folderChanged) {
            try LiveMailClient.assertUIDValidity(expected: 5, current: 6)
        }
    }

    @Test(arguments: [
        ("NO [UNAVAILABLE] Try again later", MailClientError.serverBusy),
        ("NO [LIMIT] Too many simultaneous logins", .serverBusy),
        ("NO [INUSE] Mailbox in use by another session", .serverBusy),
        ("NO Too many connections, try again later", .serverBusy),
        ("NO TOO MANY CONNECTIONS", .serverBusy),
        ("NO Invalid credentials", .authenticationFailed),
        // A wrong-password reply can say "try again" too — that alone must never flip this to
        // serverBusy the way the old, looser `classify(_:fallback:)` matching would have.
        ("NO Authentication failed, please try again", .authenticationFailed),
    ])
    func classifiesLoginFailures(text: String, expected: MailClientError) {
        #expect(LiveMailClient.classifyLoginFailure(text) == expected)
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
