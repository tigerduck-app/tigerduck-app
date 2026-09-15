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
