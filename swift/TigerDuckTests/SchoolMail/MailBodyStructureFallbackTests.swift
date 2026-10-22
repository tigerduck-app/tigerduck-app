#if os(iOS)
import Foundation
import SwiftMail
import Testing
@testable import TigerDuck

/// A mail whose `BODYSTRUCTURE` the server botches must still open.
///
/// Mail2000 sometimes describes a message in a way no IMAP parser can read. NIOIMAP does not
/// fail the FETCH but reports `MessageAttribute.BodyStructure.invalid`, kept by vendored patch 6
/// as `MessageInfo.bodyStructureUnusable`. With `parts` empty, `LiveMailClient.detail` finds no
/// body or attachments: the screen would show only the source, and `MailWarnings`, which reads
/// the subject and body, could not raise the delivery-failure warning. On that path only, the
/// client fetches the whole message and parses the MIME itself, as Android's Angus Mail does.
struct MailBodyStructureFallbackTests {

    static func unusableStructureInfo(size: Int? = 4096) -> MessageInfo {
        MessageInfo(
            sequenceNumber: SequenceNumber(1),
            uid: SwiftMail.UID(4242),
            subject: "Returned Mail: Hostname cannot be resolved",
            from: "\"Mail Deliver System\" <MAILER-DAEMON>",
            to: ["b10000001@mail.ntust.edu.tw"],
            parts: [],
            bodyStructureUnusable: true,
            additionalHeaderFields: [HeaderField(name: "Return-Path", value: "<>")],
            size: size
        )
    }

    @Test func onlyAnUnusableStructureEarnsAWholeMessageDownload() {
        var usable = Self.unusableStructureInfo()
        usable.bodyStructureUnusable = false
        #expect(!LiveMailClient.recoversByLocalParse(usable))
        #expect(LiveMailClient.recoversByLocalParse(Self.unusableStructureInfo()))
    }

    @Test func theMailThatPromptedThisRecoveryIsActuallyRecovered() {
        #expect(LiveMailClient.recoversByLocalParse(Self.unusableStructureInfo(size: 28 * 1024 * 1024)))
    }

    @Test func aMessageOverTheCeilingIsNotDownloadedWhole() {
        let cap = MailConstants.maxLocalParseBytes
        #expect(LiveMailClient.recoversByLocalParse(Self.unusableStructureInfo(size: cap)))
        #expect(!LiveMailClient.recoversByLocalParse(Self.unusableStructureInfo(size: cap + 1)))
    }

    @Test func bothDetailFetchesCarryWhatTheCeilingAndTheFlagNeed() {
        for options in [LiveMailClient.detailOptions, LiveMailClient.summaryOptions] {
            #expect(options.contains(.bodyStructure))
            #expect(options.contains(.size))
        }
    }

    @Test func anUnknownSizeIsNotReadAsOversized() {
        #expect(LiveMailClient.recoversByLocalParse(Self.unusableStructureInfo(size: nil)))
    }

    @Test func theBodyIsRecoveredByParsingTheMessageLocally() throws {
        let raw = try SchoolMailFixtures.rawEML("bounce-multipart")
        let info = Self.unusableStructureInfo()
        let summary = try #require(LiveMailClient.summary(from: info))
        #expect(info.parts.isEmpty)
        #expect(!summary.hasAttachments)

        let detail = try #require(LiveMailClient.localDetail(summary: summary, info: info, raw: raw))
        let text = try #require(detail.textBody)
        #expect(text.contains("The following addresses had delivery errors"))
        #expect(text.contains("B10000001@mail.ntust.edj.tw"))
        #expect(detail.htmlBody == nil)
        #expect(detail.parts.map(\.section) == ["1", "2"])
        #expect(detail.attachments.map(\.contentType) == ["message/rfc822"])
        #expect(detail.summary.hasAttachments)
        #expect((detail.attachments.first?.size ?? 0) > 0)
        #expect(detail.returnPath == "<>")
        #expect(detail.summary.subject == "Returned Mail: Hostname cannot be resolved")
        #expect(detail.summary.fromName == "Mail Deliver System")
    }

    @Test func aLocalParseThatFindsNothingEitherIsNotDressedUpAsARecovery() throws {
        let info = Self.unusableStructureInfo()
        let summary = try #require(LiveMailClient.summary(from: info))
        #expect(LiveMailClient.localDetail(summary: summary, info: info, raw: Data()) == nil)
    }

    @Test func theLocalParseAppliesTheAppsCharsetRules() throws {
        let raw = try SchoolMailFixtures.rawEML("big5-plain")
        let message = try EMLParser.parse(raw)
        let part = try #require(message.parts.first)
        #expect(
            LiveMailClient.decodedText(of: part)?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "中文郵件"
        )
    }

    @Test func theRecoveredBodyEarnsTheMistypedRecipientWarning() throws {
        let raw = try SchoolMailFixtures.rawEML("bounce-multipart")
        let info = Self.unusableStructureInfo()
        let summary = try #require(LiveMailClient.summary(from: info))
        let detail = try #require(LiveMailClient.localDetail(summary: summary, info: info, raw: raw))

        #expect(MailWarnings.isBounce(returnPath: detail.returnPath))
        #expect(MailWarnings.mentionsMistypedSchoolAddress(try #require(detail.textBody)))
        #expect(MailWarnings.isMistypedSchoolMailDomain("mail.ntust.edj.tw"))

        let warnings = MailWarnings.evaluate(MailWarningInput(
            fromAddress: detail.summary.fromAddress ?? "",
            fromName: detail.summary.fromName,
            subject: detail.summary.subject ?? "",
            plainText: try #require(detail.textBody),
            links: [],
            attachments: detail.attachments.map { MailAttachmentInfo(filename: $0.filename ?? "", contentType: $0.contentType) },
            returnPath: detail.returnPath
        ))
        #expect(warnings.contains(.mistypedRecipient))

        let starved = MailWarnings.evaluate(MailWarningInput(
            fromAddress: detail.summary.fromAddress ?? "",
            fromName: detail.summary.fromName,
            subject: detail.summary.subject ?? "",
            plainText: "",
            links: [],
            attachments: [],
            returnPath: detail.returnPath
        ))
        #expect(!starved.contains(.mistypedRecipient))
    }

    @MainActor
    @Test func theParseFailedBannerIsGoneAndTheWarningIsOn() async throws {
        let raw = try SchoolMailFixtures.rawEML("bounce-multipart")
        let info = Self.unusableStructureInfo()
        let summary = try #require(LiveMailClient.summary(from: info))
        var summaryWithUID = summary
        summaryWithUID.uid = 9
        let recovered = try #require(
            LiveMailClient.localDetail(summary: summaryWithUID, info: info, raw: raw)
        )

        let harness = MailMessageViewModelTests.harness(
            FakeMailClient.Message(summary: summaryWithUID, detail: recovered, raw: raw, attachments: [:], messageID: nil)
        )
        await harness.model.load()
        #expect(harness.model.loadState == .loaded)
        #expect(!harness.model.parseFailed)
        #expect(harness.model.mode == .plain)
        #expect(harness.model.warnings.contains(.mistypedRecipient))
    }

    @MainActor
    @Test func aMessageWithNothingToShowStillSaysSo() async {
        let harness = MailMessageViewModelTests.harness(
            FakeMailClient.message(uid: 11, text: nil, html: nil)
        )
        await harness.model.load()
        #expect(harness.model.parseFailed)
        #expect(harness.model.mode == .source)
    }
}
#endif
