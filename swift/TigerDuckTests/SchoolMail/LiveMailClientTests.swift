#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

struct LiveMailClientTests {
    @Test(arguments: [
        ("NIOSSLError.handshakeFailed(... CERTIFICATE_VERIFY_FAILED)", MailClientError.certificateRejected),
        ("NO [UNAVAILABLE] Too many connections", .serverBusy),
        ("server busy, try again later", .serverBusy),
        ("NO [AUTHENTICATIONFAILED] Invalid credentials", .authenticationFailed),
        ("connection reset by peer", .unreachable),
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
