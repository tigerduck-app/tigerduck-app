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
        let homograph = "n\u{0442}u\u{0455}\u{0442}.\u{0435}du.\u{0442}w"
        let issues = MailWarnings.linkIssues(text: homograph, href: "https://ntust.edu.tw/")
        #expect(issues.contains(where: { issue in
            if case .mismatch(_, let realHost) = issue { return realHost == "ntust.edu.tw" }
            return false
        }))
    }

    @Test
    func linkIssuesPlainASCIIShownHostStillMatches() {
        let issues = MailWarnings.linkIssues(text: "ntust.edu.tw", href: "https://ntust.edu.tw/")
        #expect(issues.isEmpty)
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
