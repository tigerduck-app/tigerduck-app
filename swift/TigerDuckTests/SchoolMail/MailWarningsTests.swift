#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

struct MailWarningsTests {
    struct LinkDTO: Decodable, Sendable { let text: String; let href: String }
    struct AttachmentDTO: Decodable, Sendable { let filename: String; let contentType: String? }

    struct MessageCase: Decodable, Sendable, CustomTestStringConvertible {
        let name: String
        let fromAddress: String
        let fromName: String?
        let subject: String
        let text: String
        let links: [LinkDTO]
        let attachments: [AttachmentDTO]
        let expect: [String]
        var testDescription: String { name }
    }

    struct LinkCase: Decodable, Sendable, CustomTestStringConvertible {
        let name: String
        let text: String
        let href: String
        let expect: [String]
        var testDescription: String { name }
    }

    struct Fixture: Decodable, Sendable {
        let messages: [MessageCase]
        let links: [LinkCase]
    }

    static let fixture: Fixture = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(Fixture.self, from: SchoolMailFixtures.data("warnings"))
    }()

    @Test(arguments: fixture.messages)
    func messageWarnings(_ testCase: MessageCase) {
        let input = MailWarningInput(
            fromAddress: testCase.fromAddress,
            fromName: testCase.fromName,
            subject: testCase.subject,
            plainText: testCase.text,
            links: testCase.links.map { MailLink(text: $0.text, href: $0.href) },
            attachments: testCase.attachments.map { MailAttachmentInfo(filename: $0.filename, contentType: $0.contentType) }
        )
        #expect(MailWarnings.evaluate(input).map(\.fixtureCode) == testCase.expect)
    }

    @Test(arguments: fixture.links)
    func linkIssues(_ testCase: LinkCase) {
        #expect(MailWarnings.linkIssues(text: testCase.text, href: testCase.href).map(\.fixtureCode) == testCase.expect)
    }

    // Parity gap (deferred iOS item, security-relevant, 2026-09-16): the shown-host
    // pattern used to be ASCII-only, so Unicode homograph link text was never recognized
    // as a host and never checked against the real href. These two are not fixture cases
    // (the fixture stays byte-identical to Android's) but cover the same gap directly.
    @Test
    func linkIssuesHomographShownHostMismatchesRealHost() {
        // "n\u{0442}u\u{0455}\u{0442}.\u{0435}du.\u{0442}w" reads as "ntust.edu.tw" with Cyrillic te/dze/ie
        // (U+0442/U+0455/U+0435) standing in for t/s/e -- a Unicode homograph, not ASCII.
        // Fix round 1, Minor 1: assert the full exact value (not just "some mismatch"), to
        // actually prove IDNA-to-ASCII ran and produced this specific punycode rather than
        // something incidental.
        let homograph = "n\u{0442}u\u{0455}\u{0442}.\u{0435}du.\u{0442}w"
        let issues = MailWarnings.linkIssues(text: homograph, href: "https://ntust.edu.tw/")
        #expect(issues == [.mismatch(shownHost: "xn--nu-rmcb8g.xn--du-mlc.xn--w-8tb", realHost: "ntust.edu.tw")])
    }

    @Test
    func linkIssuesPlainASCIIShownHostStillMatches() {
        let issues = MailWarnings.linkIssues(text: "ntust.edu.tw", href: "https://ntust.edu.tw/")
        #expect(issues.isEmpty)
    }

    // Fix round 1, Minor 1: prove IDNA-to-ASCII actually runs and produces the exact
    // punycode form, not just "some xn-- string".
    @Test
    func linkIssuesNonASCIIHostConvertsToExactPunycode() {
        // "nt\u{00FA}st.edu.tw" (u with acute, U+00FA) is a plausible lookalike
        // domain for "ntust.edu.tw"; its exact punycode form is asserted so this test would
        // fail if `toASCII` stopped running (or ran differently) rather than passing by luck.
        let issues = MailWarnings.linkIssues(text: "x", href: "https://nt\u{00FA}st.edu.tw/")
        #expect(issues == [.punycode(host: "xn--ntst-rra.edu.tw")])
    }

    @Test
    func linkIssuesIPv6HostKeepsItsBrackets() {
        let issues = MailWarnings.linkIssues(text: "ntust.edu.tw", href: "https://[::1]:8080/")
        #expect(issues == [.mismatch(shownHost: "ntust.edu.tw", realHost: "[::1]")])
    }

    // Fix round 1, Important 1 (2026-09-18): host/authority scanning must be on
    // `unicodeScalars`, not `Character` (extended grapheme cluster). A combining mark
    // attaches to whatever scalar precedes it, so a `Character`-based scan can merge a
    // separator like `/` into a cluster that no longer equals "/", letting the scan run
    // straight past it to a forged terminator or `@` further along.
    @Test
    func linkIssuesCombiningMarkAfterSlashCannotHideTheRealHost() {
        // The combining mark rides on the "/" right after "evil.example". A Character-based
        // scan would fail to recognize that "/" as a terminator, keep going, and find the
        // LATER "@" -- misreporting ntust.edu.tw as the real host instead of evil.example.
        let href = "https://evil.example/\u{034F}@ntust.edu.tw/login"
        let issues = MailWarnings.linkIssues(text: "ntust.edu.tw", href: href)
        #expect(issues == [.mismatch(shownHost: "ntust.edu.tw", realHost: "evil.example")])
    }

    @Test
    func linkIssuesCombiningMarkCannotHideAPunycodeHost() {
        // Same trick, this time hiding a punycode host's own "/" terminator so the "xn--"
        // host gets folded into a fake userinfo instead of being flagged as punycode.
        let href = "https://xn--ntst-0ra.edu.tw/\u{034F}@ntust.edu.tw"
        let issues = MailWarnings.linkIssues(text: "xn--ntst-0ra.edu.tw", href: href)
        #expect(issues == [.punycode(host: "xn--ntst-0ra.edu.tw")])
    }

    @Test
    func linkIssuesCombiningMarkCannotHideTheInsecureFlag() {
        // The mark rides on the second "/" of "http://", so a Character-based
        // `hasPrefix("http://")` would fail to match at all and silently drop the insecure
        // flag. IDNA mapping drops the combining mark itself (it is Unicode "ignored" for
        // IDNA), so the real host still comes out as plain "evil.example".
        let href = "http://\u{034F}evil.example/"
        let issues = MailWarnings.linkIssues(text: "evil.example", href: href)
        #expect(issues == [.insecure])
    }

    // Fix round 1, Important 2 (2026-09-18): ICU's `.` (used by NSRegularExpression)
    // excludes U+000B/U+000C from "any character", unlike Java's `.` which matches them
    // like ordinary characters. Both patterns now use an explicit
    // "[^\n\r\u0085\u2028\u2029]" class so a vertical tab in link text does not break
    // the whole-string match and silently suppress a real mismatch the way plain `.*` would
    // have on iOS (but not on Android).
    @Test
    func linkIssuesVerticalTabInTextStillAllowsAMismatch() {
        let href = "https://evil.example/"
        let text = "ntust.edu.tw/\u{000B}login"
        let issues = MailWarnings.linkIssues(text: text, href: href)
        #expect(issues == [.mismatch(shownHost: "ntust.edu.tw", realHost: "evil.example")])
    }
}

private extension MailWarning {
    var fixtureCode: String {
        switch self {
        case .externalSender(let address): "external_sender:\(address)"
        case .displayNameMismatch(let address): "display_name_mismatch:\(address)"
        case .passwordBait: "password_bait"
        case .riskyAttachment(let filename, let reason): "risky_attachment:\(filename):\(reason.fixtureCode)"
        }
    }
}

private extension MailRiskReason {
    var fixtureCode: String {
        switch self {
        case .dangerousExtension: "dangerous_extension"
        case .doubleExtension: "double_extension"
        case .typeMismatch: "type_mismatch"
        case .encryptedArchive: "encrypted_archive"
        }
    }
}

private extension MailLinkIssue {
    var fixtureCode: String {
        switch self {
        case .insecure: "insecure"
        case .punycode(let host): "punycode:\(host)"
        case .mismatch(let shown, let real): "mismatch:\(shown):\(real)"
        }
    }
}
#endif
