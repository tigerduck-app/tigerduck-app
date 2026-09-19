#if os(iOS)
import Foundation
import SwiftMail
import Testing
@testable import TigerDuck

/// A mail whose `BODYSTRUCTURE` the server botches must still open.
///
/// Mail2000 sometimes describes its own message in a way no IMAP parser can read. NIOIMAP does
/// not fail the FETCH over it — it reports `MessageAttribute.BodyStructure.invalid` — but until
/// vendored patch 6 that verdict was dropped on the floor, so `MessageInfo.parts` came back empty
/// and `LiveMailClient.detail` iterated nothing: no `textBody`, no `htmlBody`, no attachments.
/// The message screen then showed 「無法解析這封信的格式，改為原始碼」 and, because
/// `MailWarnings` reads a haystack built from the subject and the body, the delivery-failure
/// warning that belonged on that very mail could not fire either.
///
/// Android never had the bug: Angus Mail fetches the message and parses the MIME itself rather
/// than trusting the server's description of it. This is iOS doing the same, on the one path
/// where the description turned out to be worthless.
struct MailBodyStructureFallbackTests {

    /// What the detail fetch comes back with for such a message: everything except the structure.
    /// The envelope, the flags, the size and the full header section all decoded fine — only the
    /// `BODYSTRUCTURE` did not, which is exactly why an empty `parts` is not the whole story.
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

    // MARK: The ceiling

    @Test func onlyAnUnusableStructureEarnsAWholeMessageDownload() {
        // The normal path must stay exactly as cheap as it is. A message that genuinely has no
        // parts looks identical from the outside — same empty `parts` — and must not start
        // downloading itself.
        var usable = Self.unusableStructureInfo()
        usable.bodyStructureUnusable = false
        #expect(!LiveMailClient.recoversByLocalParse(usable))
        #expect(LiveMailClient.recoversByLocalParse(Self.unusableStructureInfo()))
    }

    @Test func theMailThatPromptedThisRecoveryIsActuallyRecovered() {
        // Regression, and the whole point of the feature. This test previously asserted the
        // opposite — that a 28 MB message is refused — because the ceiling was borrowed from
        // `MailCache`'s per-entry limit (10 MB). The real Mail2000 bounce is 28.2 MB, so the
        // guard turned away the one message the recovery exists for, and it went on showing
        // 「無法解析這封信的格式」 on a device after the fix shipped.
        //
        // Refusing to parse saves nothing: `parseFailed` forces 原始碼 and the view immediately
        // calls `loadSource()`, so the whole message is fetched either way. The only thing the
        // old ceiling bought above 10 MB was an unreadable dump for the same bytes.
        #expect(LiveMailClient.recoversByLocalParse(Self.unusableStructureInfo(size: 28 * 1024 * 1024)))
    }

    @Test func aMessageOverTheCeilingIsNotDownloadedWhole() {
        // A bound still exists, so a pathological message is not held in memory twice — it is
        // just the size this app already calls the largest single message it deals with
        // (`maxEncodedMessageBytes`), not the cache's storage ceiling.
        let cap = MailConstants.maxLocalParseBytes
        #expect(LiveMailClient.recoversByLocalParse(Self.unusableStructureInfo(size: cap)))
        #expect(!LiveMailClient.recoversByLocalParse(Self.unusableStructureInfo(size: cap + 1)))
    }

    @Test func bothDetailFetchesCarryWhatTheCeilingAndTheFlagNeed() {
        // The two halves compose: `detailInfo` retries a protocol error with the summary
        // attributes, and those still ask for BODYSTRUCTURE — so a message whose structure is
        // unusable is still recognised as such after the header section has been dropped. Both
        // sets ask for RFC822.SIZE, which is what makes the ceiling knowable before any body
        // byte is fetched.
        for options in [LiveMailClient.detailOptions, LiveMailClient.summaryOptions] {
            #expect(options.contains(.bodyStructure))
            #expect(options.contains(.size))
        }
    }

    @Test func anUnknownSizeIsNotReadAsOversized() {
        // Both fetch option sets ask for RFC822.SIZE, so this is the shape of a server that
        // ignored an attribute it was asked for. Treating that as "too large" would let such a
        // server switch the whole recovery off, which is the opposite of the point.
        #expect(LiveMailClient.recoversByLocalParse(Self.unusableStructureInfo(size: nil)))
    }

    // MARK: The recovery

    @Test func theBodyIsRecoveredByParsingTheMessageLocally() throws {
        let raw = try SchoolMailFixtures.rawEML("bounce-multipart")
        let info = Self.unusableStructureInfo()
        let summary = try #require(LiveMailClient.summary(from: info))
        // What the server said about this message: nothing usable.
        #expect(info.parts.isEmpty)
        #expect(!summary.hasAttachments)

        let detail = try #require(LiveMailClient.localDetail(summary: summary, info: info, raw: raw))
        let text = try #require(detail.textBody)
        #expect(text.contains("The following addresses had delivery errors"))
        #expect(text.contains("B10000001@mail.ntust.edj.tw"))
        #expect(detail.htmlBody == nil)
        // The returned original: one attachment, at the section the local parse assigned it.
        #expect(detail.parts.map(\.section) == ["1", "2"])
        #expect(detail.attachments.map(\.contentType) == ["message/rfc822"])
        #expect(detail.summary.hasAttachments)
        // A part from a local parse has no BODYSTRUCTURE octet count; its own bytes are it.
        #expect((detail.attachments.first?.size ?? 0) > 0)
        // Everything that did not come from the structure still comes from the fetch.
        #expect(detail.returnPath == "<>")
        #expect(detail.summary.subject == "Returned Mail: Hostname cannot be resolved")
        #expect(detail.summary.fromName == "Mail Deliver System")
    }

    @Test func aLocalParseThatFindsNothingEitherIsNotDressedUpAsARecovery() throws {
        // Then the caller falls through to the ordinary (empty) result and the screen says what
        // it has always said — rather than reporting a body that was never found.
        let info = Self.unusableStructureInfo()
        let summary = try #require(LiveMailClient.summary(from: info))
        #expect(LiveMailClient.localDetail(summary: summary, info: info, raw: Data()) == nil)
    }

    @Test func theLocalParseAppliesTheAppsCharsetRules() throws {
        // The same two steps the server path applies to a fetched part, in the same order:
        // transfer-decode, then decode the bytes with the Appendix A.5 charset rules — not
        // EMLParser's own Big5-blind fallback chain.
        let raw = try SchoolMailFixtures.rawEML("big5-plain")
        let message = try EMLParser.parse(raw)
        let part = try #require(message.parts.first)
        #expect(
            LiveMailClient.decodedText(of: part)?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "中文郵件"
        )
    }

    // MARK: Symptom 2 — the warning the empty body swallowed

    @Test func theRecoveredBodyEarnsTheMistypedRecipientWarning() throws {
        let raw = try SchoolMailFixtures.rawEML("bounce-multipart")
        let info = Self.unusableStructureInfo()
        let summary = try #require(LiveMailClient.summary(from: info))
        let detail = try #require(LiveMailClient.localDetail(summary: summary, info: info, raw: raw))

        // `Return-Path: <>` makes it a bounce; the recovered body is what names the near-miss
        // domain. Neither half alone produces the warning.
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

        // And with the body the bug left empty, it cannot fire — which is the whole of why
        // symptom 2 was downstream of symptom 1, not a second defect.
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

    // MARK: The message screen

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
        // Not forced into 原始碼 any more; a mail with no HTML part lands on 純文字.
        #expect(harness.model.mode == .plain)
        #expect(harness.model.warnings.contains(.mistypedRecipient))
    }

    @MainActor
    @Test func aMessageWithNothingToShowStillSaysSo() async {
        // The residue `parseFailed` still covers: no body, no attachments, nothing to render.
        let harness = MailMessageViewModelTests.harness(
            FakeMailClient.message(uid: 11, text: nil, html: nil)
        )
        await harness.model.load()
        #expect(harness.model.parseFailed)
        #expect(harness.model.mode == .source)
    }
}
#endif
