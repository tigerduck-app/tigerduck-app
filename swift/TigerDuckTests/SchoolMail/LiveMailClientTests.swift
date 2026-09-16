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

    @Test func unknownErrorsCountAsUnreachable() {
        #expect(LiveMailClient.map(URLError(.timedOut)) == .unreachable)
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

    @Test func uidValidityChangeDetection() {
        // Nothing recorded yet for the folder: never a mismatch — a different layer
        // (`MailMover.assertFolderUnchanged`) is relied on to have checked already.
        #expect(!LiveMailClient.uidValidityChanged(remembered: nil, current: 5))
        #expect(!LiveMailClient.uidValidityChanged(remembered: 5, current: 5))
        #expect(LiveMailClient.uidValidityChanged(remembered: 5, current: 6))
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
