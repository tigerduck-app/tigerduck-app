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

    @Test
    func linkIssuesHomographShownHostMismatchesRealHost() {
        let homograph = "n\u{0442}u\u{0455}\u{0442}.\u{0435}du.\u{0442}w"
        let issues = MailWarnings.linkIssues(text: homograph, href: "https://ntust.edu.tw/")
        #expect(issues == [.mismatch(shownHost: "xn--nu-rmcb8g.xn--du-mlc.xn--w-8tb", realHost: "ntust.edu.tw")])
    }

    @Test
    func linkIssuesPlainASCIIShownHostStillMatches() {
        let issues = MailWarnings.linkIssues(text: "ntust.edu.tw", href: "https://ntust.edu.tw/")
        #expect(issues.isEmpty)
    }

    @Test
    func linkIssuesNonASCIIHostConvertsToExactPunycode() {
        let issues = MailWarnings.linkIssues(text: "x", href: "https://nt\u{00FA}st.edu.tw/")
        #expect(issues == [.punycode(host: "xn--ntst-rra.edu.tw")])
    }

    @Test
    func linkIssuesIPv6HostKeepsItsBrackets() {
        let issues = MailWarnings.linkIssues(text: "ntust.edu.tw", href: "https://[::1]:8080/")
        #expect(issues == [.mismatch(shownHost: "ntust.edu.tw", realHost: "[::1]")])
    }

    @Test
    func linkIssuesCombiningMarkAfterSlashCannotHideTheRealHost() {
        let href = "https://evil.example/\u{034F}@ntust.edu.tw/login"
        let issues = MailWarnings.linkIssues(text: "ntust.edu.tw", href: href)
        #expect(issues == [.mismatch(shownHost: "ntust.edu.tw", realHost: "evil.example")])
    }

    @Test
    func linkIssuesCombiningMarkCannotHideAPunycodeHost() {
        let href = "https://xn--ntst-0ra.edu.tw/\u{034F}@ntust.edu.tw"
        let issues = MailWarnings.linkIssues(text: "xn--ntst-0ra.edu.tw", href: href)
        #expect(issues == [.punycode(host: "xn--ntst-0ra.edu.tw")])
    }

    @Test
    func linkIssuesCombiningMarkCannotHideTheInsecureFlag() {
        let href = "http://\u{034F}evil.example/"
        let issues = MailWarnings.linkIssues(text: "evil.example", href: href)
        #expect(issues == [.insecure])
    }

    @Test
    func linkIssuesVerticalTabInTextStillAllowsAMismatch() {
        let href = "https://evil.example/"
        let text = "ntust.edu.tw/\u{000B}login"
        let issues = MailWarnings.linkIssues(text: text, href: href)
        #expect(issues == [.mismatch(shownHost: "ntust.edu.tw", realHost: "evil.example")])
    }

    @Test
    func linkIssuesInvisibleCharacterInsideTheShownHostStillMismatches() {
        let issues = MailWarnings.linkIssues(text: "ntust.e\u{200B}du.tw", href: "https://evil.example/login")
        #expect(issues == [.mismatch(shownHost: "ntust.edu.tw", realHost: "evil.example")])
    }

    @Test
    func linkIssuesInvisibleCharacterInMailtoLinkTextStillMismatches() {
        let issues = MailWarnings.linkIssues(
            text: "admin@mail.ntust.e\u{200B}du.tw",
            href: "mailto:phish@evil.example"
        )
        #expect(issues == [.mismatch(shownHost: "admin@mail.ntust.edu.tw", realHost: "phish@evil.example")])
    }

    @Test
    func displayNameMismatchSurvivesAnInvisibleCharacterInTheFakeAddress() {
        let input = MailWarningInput(
            fromAddress: "b10123456@mail.ntust.edu.tw",
            fromName: "no-reply@ntust.e\u{200B}du.tw",
            subject: "x",
            plainText: "",
            links: [],
            attachments: []
        )
        #expect(MailWarnings.evaluate(input) == [.displayNameMismatch(address: "b10123456@mail.ntust.edu.tw")])
    }

    @Test
    func displayNameMismatchDetectsANonASCIILocalPart() {
        let input = MailWarningInput(
            fromAddress: "x@gmail.com",
            fromName: "客服 帳務@evil.example",
            subject: "x",
            plainText: "",
            links: [],
            attachments: []
        )
        #expect(MailWarnings.evaluate(input) == [
            .externalSender(address: "x@gmail.com"),
            .displayNameMismatch(address: "x@gmail.com"),
        ])
    }

    @Test
    func displayNameMismatchDetectsASingleLetterTLD() {
        let input = MailWarningInput(
            fromAddress: "x@gmail.com",
            fromName: "service@evil.c",
            subject: "x",
            plainText: "",
            links: [],
            attachments: []
        )
        #expect(MailWarnings.evaluate(input) == [
            .externalSender(address: "x@gmail.com"),
            .displayNameMismatch(address: "x@gmail.com"),
        ])
    }

    @Test
    func anEmptySenderAddressRaisesNoExternalBanner() {
        let input = MailWarningInput(
            fromAddress: "",
            fromName: "Mail Deliver System",
            subject: "Returned Mail: Hostname cannot be resolved",
            plainText: "The following addresses had delivery errors",
            links: [],
            attachments: []
        )
        #expect(MailWarnings.evaluate(input).isEmpty)
        #expect(MailWarnings.domain(ofAddress: "") == "")
        #expect(!MailWarnings.isSchoolDomain(""))
    }

    @Test
    func onlyANullReversePathMarksABounce() {
        #expect(MailWarnings.isBounce(returnPath: "<>"))
        #expect(MailWarnings.isBounce(returnPath: "  <> "), "folding whitespace is not part of the value")
        #expect(!MailWarnings.isBounce(returnPath: nil))
        #expect(!MailWarnings.isBounce(returnPath: ""))
        #expect(!MailWarnings.isBounce(returnPath: "<postmaster@mail.ntust.edu.tw>"))
        #expect(!MailWarnings.isBounce(returnPath: "Mail Deliver System"))
    }

    @Test
    func aMail2000BounceIsNotTreatedAsOutsideMailAndAsksAboutTheTypo() {
        let input = MailWarningInput(
            fromAddress: "",
            fromName: "Mail Deliver System",
            subject: "Returned Mail: Hostname cannot be resolved",
            plainText: """
            The original message was received from b10000001@mail.ntust.edu.tw
            ---The following addresses had delivery errors---
            B10000001@mail.ntust.edj.tw [Hostname cannot be resolved]
            """,
            links: [],
            attachments: [],
            returnPath: "<>"
        )
        #expect(MailWarnings.evaluate(input) == [.mistypedRecipient])
        #expect(MailMessageView.text(for: .mistypedRecipient) == String(localized: "school_mail_bounce_warning"))
    }

    @Test
    func theBounceExemptionIsNarrowAndPasswordBaitStillFires() {
        func evaluate(from: String, links: [MailLink] = []) -> [MailWarning] {
            MailWarnings.evaluate(MailWarningInput(
                fromAddress: from, fromName: "Mail Deliver System", subject: "Returned Mail: 帳號停用",
                plainText: "verify", links: links, attachments: [], returnPath: "<>"
            ))
        }
        #expect(evaluate(from: "daemon@evil.example").contains(.externalSender(address: "daemon@evil.example")))
        #expect(evaluate(from: "daemon@mail.ntust.edu.tw").isEmpty)
        #expect(evaluate(from: "").isEmpty)
        #expect(evaluate(from: "", links: [MailLink(text: "verify", href: "https://evil.example/login")])
            .contains(.passwordBait))
    }

    @Test
    func withoutAReturnPathABounceShapedMailIsJudgedExactlyAsBefore() {
        let input = MailWarningInput(
            fromAddress: "", fromName: "Mail Deliver System", subject: "Returned Mail: 帳號停用",
            plainText: "please verify <B10000001@mail.ntust.edj.tw>", links: [], attachments: []
        )
        #expect(MailWarnings.evaluate(input) == [.passwordBait])
    }

    @Test
    func aNearMissOfTheSchoolMailDomainIsATypoAndAnExactOrUnrelatedOneIsNot() {
        #expect(MailWarnings.isMistypedSchoolMailDomain("mail.ntust.edj.tw"), "edj for edu")
        #expect(MailWarnings.isMistypedSchoolMailDomain("mail.ntsut.edu.tw"), "a transposition is two edits")
        #expect(MailWarnings.isMistypedSchoolMailDomain("MAIL.NTUST.EDU.TW2"))
        #expect(!MailWarnings.isMistypedSchoolMailDomain("mail.ntust.edu.tw"), "not a typo of itself")
        #expect(!MailWarnings.isMistypedSchoolMailDomain("ntust.edu.tw"), "nor is another real school domain")
        #expect(!MailWarnings.isMistypedSchoolMailDomain("gmail.com"))
        #expect(!MailWarnings.isMistypedSchoolMailDomain("mail.ntust.edu.tw.evil.example"))
        #expect(!MailWarnings.isMistypedSchoolMailDomain(""))
    }

    @Test
    func onlyABounceNamingANearMissAsksAboutATypo() {
        func bounce(_ text: String) -> [MailWarning] {
            MailWarnings.evaluate(MailWarningInput(
                fromAddress: "", fromName: "Mail Deliver System",
                subject: "Returned Mail: Hostname cannot be resolved",
                plainText: text, links: [], attachments: [], returnPath: "<>"
            ))
        }
        #expect(bounce("<B10000001@mail.ntust.edj.tw>: Hostname cannot be resolved").contains(.mistypedRecipient))
        #expect(!bounce("<someone@gmail.com>: user unknown").contains(.mistypedRecipient),
                "nothing says a gmail address was meant to be ours")
        #expect(!bounce("<B10000001@mail.ntust.edu.tw>: mailbox full").contains(.mistypedRecipient))
        #expect(!bounce("no address at all here").contains(.mistypedRecipient))
    }

    @Test
    func anEmptySenderAddressStillFailsTheDisplayNameCheck() {
        let input = MailWarningInput(
            fromAddress: "",
            fromName: "教務處 office@ntust.edu.tw",
            subject: "x",
            plainText: "",
            links: [],
            attachments: []
        )
        #expect(MailWarnings.evaluate(input) == [.displayNameMismatch(address: "")])
        #expect(MailMessageView.text(for: .displayNameMismatch(address: ""))
            == String(localized: "school_mail_warning_display_name"))
    }

    @Test
    func anEmptySenderAddressStillCountsAsOutsideForPasswordBait() {
        let input = MailWarningInput(
            fromAddress: "",
            fromName: "信箱管理員",
            subject: "您的信箱容量已滿",
            plainText: "請立即驗證",
            links: [],
            attachments: []
        )
        #expect(MailWarnings.evaluate(input) == [.passwordBait])
    }

    @Test(arguments: [
        "payload.ex\u{200B}e",
        "installer.ap\u{2060}k",
        "setup.apk\u{0001}",
        "run.sc\u{00AD}r",
    ])
    func attachmentRiskSurvivesAnInvisibleCharacterInTheExtension(filename: String) {
        #expect(
            MailWarnings.attachmentRisk(filename: filename, contentType: "application/octet-stream", subjectAndBody: "")
                == .dangerousExtension
        )
    }

    @Test(arguments: ["report.ht\u{200B}ml", "diagram.sv\u{0001}g", "page.xhtm\u{2060}l"])
    func neverRenderedInAppSurvivesAnInvisibleCharacterInTheExtension(filename: String) {
        #expect(MailWarnings.neverRenderedInApp(filename: filename))
    }

    @Test(arguments: ["您的密\u{200B}碼即將到期", "Please re-enter your pass\u{200B}word"])
    func passwordBaitSurvivesAnInvisibleCharacterInTheKeyword(subject: String) {
        let input = MailWarningInput(
            fromAddress: "admin@evil.example",
            fromName: nil,
            subject: subject,
            plainText: "",
            links: [],
            attachments: []
        )
        #expect(MailWarnings.evaluate(input) == [.externalSender(address: "admin@evil.example"), .passwordBait])
    }

    static let invisibleMarks = [
        "\u{034F}", "\u{FE0F}", "\u{FE00}", "\u{E0100}", "\u{2065}", "\u{3164}", "\u{2800}",
    ]

    @Test(arguments: invisibleMarks)
    func linkMismatchSurvivesAnInvisibleMarkInsideTheShownHost(mark: String) {
        let issues = MailWarnings.linkIssues(text: "ntust.e\(mark)du.tw", href: "https://evil.example/login")
        #expect(issues == [.mismatch(shownHost: "ntust.edu.tw", realHost: "evil.example")])
    }

    @Test(arguments: invisibleMarks)
    func neverRenderedInAppSurvivesAnInvisibleMarkInTheExtension(mark: String) {
        #expect(MailWarnings.neverRenderedInApp(filename: "report.ht\(mark)ml"))
    }

    @Test(arguments: invisibleMarks)
    func attachmentRiskSurvivesAnInvisibleMarkInTheExtension(mark: String) {
        #expect(
            MailWarnings.attachmentRisk(filename: "payload.ex\(mark)e", contentType: nil, subjectAndBody: "")
                == .dangerousExtension
        )
    }

    @Test(arguments: invisibleMarks)
    func passwordBaitSurvivesAnInvisibleMarkInTheKeyword(mark: String) {
        let input = MailWarningInput(
            fromAddress: "admin@evil.example",
            fromName: nil,
            subject: "請重新驗\(mark)證您的帳戶",
            plainText: "",
            links: [],
            attachments: []
        )
        #expect(MailWarnings.evaluate(input) == [.externalSender(address: "admin@evil.example"), .passwordBait])
    }

    @Test func aVisibleCombiningMarkIsNotTreatedAsInvisible() {
        #expect(MailWarnings.attachmentRisk(filename: "payload.ex\u{0301}e", contentType: nil, subjectAndBody: "") == nil)
        #expect(!MailWarnings.neverRenderedInApp(filename: "report.ht\u{0301}ml"))
    }

    @Test(arguments: ["ntust.\nedu.tw", "ntust\n.edu.tw", "ntust.\u{00A0}edu.tw", "ntust.  edu.tw"])
    func aHostSplitAcrossALineBreakIsStillComparedAsOneHost(rawText: String) {
        let asTheSanitizerHandsItOn = MailTextCleaner.clean(rawText)
        let issues = MailWarnings.linkIssues(text: asTheSanitizerHandsItOn, href: "https://evil.example/login")
        #expect(issues == [.mismatch(shownHost: "ntust.edu.tw", realHost: "evil.example")])
    }

    @Test(arguments: ["按這裡 看公告", "Reset your password here", "請見 ntust.edu.tw 公告", "點我 立即 驗證"])
    func ordinaryWordsAroundALinkAreStillNotAHost(text: String) {
        #expect(MailWarnings.linkIssues(text: text, href: "https://evil.example/login").isEmpty)
    }

    @Test
    func encryptedArchiveHintSurvivesAnInvisibleCharacterInTheKeyword() {
        #expect(
            MailWarnings.attachmentRisk(filename: "data.zip", contentType: "application/zip", subjectAndBody: "檔案的解\u{200B}壓縮方式請見附件")
                == .encryptedArchive
        )
    }
}

private extension MailWarning {
    var fixtureCode: String {
        switch self {
        case .externalSender(let address): "external_sender:\(address)"
        case .displayNameMismatch(let address): "display_name_mismatch:\(address)"
        case .passwordBait: "password_bait"
        case .riskyAttachment(let filename, let reason): "risky_attachment:\(filename):\(reason.fixtureCode)"
        case .mistypedRecipient: "mistyped_recipient"
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
