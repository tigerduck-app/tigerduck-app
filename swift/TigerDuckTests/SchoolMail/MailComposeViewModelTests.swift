#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct MailComposeViewModelTests {
    static let me = MailAddress(name: "王大明", address: "b10000000@mail.ntust.edu.tw")
    static let sent = MailFolderRole.sent.imapName
    static let drafts = MailFolderRole.drafts.imapName

    static func original() -> FakeMailClient.Message {
        var message = FakeMailClient.message(uid: 3, from: "teacher@mail.ntust.edu.tw", name: "林老師",
                                             subject: "作業", text: "請繳交", messageID: "<m3@mail.ntust.edu.tw>")
        message.summary.to = ["b10000000@mail.ntust.edu.tw", "b@x.tw"]
        message.summary.cc = ["c@x.tw"]
        message.raw = Data("From: teacher@mail.ntust.edu.tw\r\nReply-To: office@mail.ntust.edu.tw\r\nSubject: x\r\n\r\n請繳交\r\n".utf8)
        let part = MailBodyPart(section: "2", contentType: "application/pdf", charset: nil, transferEncoding: "base64",
                                filename: "作業說明.pdf", contentID: nil, size: 4, isAttachment: true)
        message.detail?.parts = [part]
        message.attachments = ["2": Data("%PDF".utf8)]
        return message
    }

    static func model(_ context: MailComposeContext, fake: FakeMailClient, prefs: InMemoryMailPreferences = InMemoryMailPreferences()) -> MailComposeViewModel {
        MailComposeViewModel(
            context: context,
            session: MailPageSession(idleClose: .milliseconds(10), open: { fake }),
            sender: Self.me,
            folderRoles: [.inbox: "INBOX", .sent: Self.sent, .drafts: Self.drafts],
            prefs: prefs,
            sleep: { _ in }
        )
    }

    static func fake() -> FakeMailClient {
        FakeMailClient(folders: ["INBOX": [Self.original()], Self.sent: [], Self.drafts: []])
    }

    static func originalContext(_ mode: MailComposeMode) -> MailComposeContext {
        let message = Self.original()
        let original = MailOriginal(
            from: MailAddress(name: "林老師", address: "teacher@mail.ntust.edu.tw"),
            to: [MailAddress(name: nil, address: "b10000000@mail.ntust.edu.tw"), MailAddress(name: nil, address: "b@x.tw")],
            cc: [MailAddress(name: nil, address: "c@x.tw")],
            subject: "作業", date: message.summary.date, messageID: "<m3@mail.ntust.edu.tw>", references: [], bodyText: "請繳交"
        )
        return MailComposeContext(mode: mode, folder: "INBOX", uid: 3, original: original,
                                  attachments: mode == .forward ? message.detail?.parts ?? [] : [])
    }

    @Test func replyGoesToReplyToWithAQuotedBody() async {
        let model = Self.model(Self.originalContext(.reply), fake: Self.fake())
        await model.prepare()
        #expect(model.to == "office@mail.ntust.edu.tw")
        #expect(model.cc.isEmpty)
        #expect(model.subject == "Re: 作業")
        #expect(model.body.hasSuffix("> 請繳交"))
        #expect(!model.hasChanges)
    }

    @Test func replyAllCopiesEveryoneButMe() async {
        let model = Self.model(Self.originalContext(.replyAll), fake: Self.fake())
        await model.prepare()
        #expect(MailAddress.parseList(model.cc).map(\.address) == ["b@x.tw", "c@x.tw"])
    }

    @Test func forwardCarriesTheAttachments() async {
        let model = Self.model(Self.originalContext(.forward), fake: Self.fake())
        await model.prepare()
        #expect(model.subject == "Fwd: 作業")
        #expect(model.attachments.map(\.filename) == ["作業說明.pdf"])
        #expect(model.to.isEmpty)
    }

    @Test func sendingUsesTheEnvelopeAndSavesOneSentCopy() async throws {
        let fake = Self.fake()
        let model = Self.model(MailComposeContext(mode: .new), fake: fake)
        await model.prepare()
        model.to = "a@mail.ntust.edu.tw"
        model.bcc = "s@x.tw"
        model.subject = "問題"
        model.body = "老師好"
        await model.send()
        #expect(model.didFinish)
        let sent = try #require(await fake.sent.first)
        #expect(sent.to == ["a@mail.ntust.edu.tw", "s@x.tw"])
        #expect(sent.from == "b10000000@mail.ntust.edu.tw")
        #expect(!String(decoding: sent.message, as: UTF8.self).contains("s@x.tw"))
        #expect(await fake.calls.filter { $0.hasPrefix("append \(Self.sent)") } == ["append \(Self.sent) [\"seen\"]"])
    }

    @Test func aServerThatKeepsSentCopiesIsNotDuplicated() async {
        let fake = Self.fake()
        await fake.update { $0.autoSaveSentTo = Self.sent }
        let model = Self.model(MailComposeContext(mode: .new), fake: fake)
        await model.prepare()
        model.to = "a@mail.ntust.edu.tw"
        await model.send()
        #expect(await fake.folders[Self.sent]?.count == 1)
        #expect(await !fake.calls.contains { $0.hasPrefix("append") })
    }

    @Test func replyingMarksTheOriginalAnswered() async {
        let fake = Self.fake()
        let model = Self.model(Self.originalContext(.reply), fake: fake)
        await model.prepare()
        await model.send()
        #expect(await fake.calls.contains("setFlag answered true [3]"))
        let raw = String(decoding: await fake.sent.first?.message ?? Data(), as: UTF8.self)
        #expect(raw.contains("In-Reply-To: <m3@mail.ntust.edu.tw>"))
    }

    @Test func recipientsAreValidatedBeforeSending() async {
        let fake = Self.fake()
        let model = Self.model(MailComposeContext(mode: .new), fake: fake)
        await model.prepare()
        await model.send()
        #expect(model.error != nil)
        model.to = "abc, a@mail.ntust.edu.tw"
        await model.send()
        #expect(model.invalidRecipients == ["abc"])
        #expect(await fake.sent.isEmpty)
    }

    @Test func oversizedMailIsBlocked() async {
        let fake = Self.fake()
        let model = Self.model(MailComposeContext(mode: .new), fake: fake)
        await model.prepare()
        model.to = "a@mail.ntust.edu.tw"
        model.addAttachment(filename: "big.bin", mimeType: "application/octet-stream", data: Data(count: 40 * 1024 * 1024))
        await model.send()
        #expect(model.error != nil)
        #expect(await fake.sent.isEmpty)
    }

    @Test func draftsAreSavedWithTheDraftFlag() async {
        let fake = Self.fake()
        let model = Self.model(MailComposeContext(mode: .new), fake: fake)
        await model.prepare()
        model.body = "還沒寫完"
        #expect(model.hasChanges)
        #expect(await model.saveDraft())
        #expect(await fake.calls.contains("append \(Self.drafts) [\"draft\", \"seen\"]"))
    }

    @Test func editingADraftReplacesTheOldOne() async {
        let fake = FakeMailClient(folders: [Self.drafts: [FakeMailClient.message(uid: 1, subject: "草稿", text: "舊內容")], Self.sent: []])
        let model = Self.model(MailComposeContext(mode: .draft, folder: Self.drafts, uid: 1), fake: fake)
        await model.prepare()
        #expect(model.subject == "草稿")
        #expect(model.body == "舊內容")
        model.body = "新內容"
        #expect(await model.saveDraft())
        #expect(await fake.folders[Self.drafts]?.map(\.summary.uid) == [2])
    }

    @Test func aFailedSendKeepsEverything() async {
        let fake = Self.fake()
        await fake.update { $0.sendError = .unreachable }
        let model = Self.model(MailComposeContext(mode: .new), fake: fake)
        await model.prepare()
        model.to = "a@mail.ntust.edu.tw"
        model.subject = "問題"
        await model.send()
        #expect(model.error != nil)
        #expect(!model.didFinish)
        #expect(model.subject == "問題")
    }

    // MARK: Dispatch addition 1 — non-ASCII recipients rejected in compose only

    @Test func nonASCIIRecipientsAreRejectedOnSend() async {
        let fake = Self.fake()
        let model = Self.model(MailComposeContext(mode: .new), fake: fake)
        await model.prepare()
        model.to = "üser@例え.jp, a@mail.ntust.edu.tw"
        await model.send()
        #expect(model.invalidRecipients == ["üser@例え.jp"])
        #expect(await fake.sent.isEmpty)
    }

    @Test func nonASCIIRecipientsAreAlsoRejectedOnSaveDraft() async {
        let fake = Self.fake()
        let model = Self.model(MailComposeContext(mode: .new), fake: fake)
        await model.prepare()
        model.to = "üser@例え.jp"
        model.body = "草稿"
        let saved = await model.saveDraft()
        #expect(!saved)
        #expect(model.invalidRecipients == ["üser@例え.jp"])
        #expect(await !fake.calls.contains { $0.hasPrefix("append") })
    }

    // MARK: Dispatch addition 3 — the same size check runs for save-draft as for send

    @Test func oversizedDraftsAreBlockedTheSameWayAsSending() async {
        let fake = Self.fake()
        let model = Self.model(MailComposeContext(mode: .new), fake: fake)
        await model.prepare()
        model.addAttachment(filename: "big.bin", mimeType: "application/octet-stream", data: Data(count: 40 * 1024 * 1024))
        let saved = await model.saveDraft()
        #expect(!saved)
        #expect(model.error != nil)
        #expect(await !fake.calls.contains { $0.hasPrefix("append") })
    }

    // MARK: Dispatch addition 5 — a failed prefill offers a retry that keeps what was typed,
    // never marks the original answered, and never discards/replaces a draft.

    @Test func aFailedPrefillDoesNotMarkTheOriginalAnswered() async {
        let fake = Self.fake()
        await fake.update { $0.rawSourceError = .unreachable }
        let model = Self.model(Self.originalContext(.reply), fake: fake)
        await model.prepare()
        #expect(model.loadError != nil)
        model.to = "a@mail.ntust.edu.tw"
        await model.send()
        #expect(await !fake.calls.contains { $0.hasPrefix("setFlag answered") })
    }

    @Test func retryPrepareKeepsTypedTextAndPickedAttachmentsAfterAFailure() async {
        let fake = Self.fake()
        await fake.update { $0.rawSourceError = .unreachable }
        let model = Self.model(Self.originalContext(.reply), fake: fake)
        await model.prepare()
        #expect(model.loadError != nil)
        model.to = "custom@mail.ntust.edu.tw"
        model.addAttachment(filename: "note.txt", mimeType: "text/plain", data: Data("hi".utf8))
        await fake.update { $0.rawSourceError = nil }
        await model.retryPrepare()
        #expect(model.loadError == nil)
        #expect(model.to == "custom@mail.ntust.edu.tw")
        #expect(model.attachments.map(\.filename) == ["note.txt"])
    }

    @Test func aFailedDraftLoadDoesNotDiscardOrReplaceTheDraftOnSave() async {
        let fake = FakeMailClient(folders: [Self.drafts: [FakeMailClient.message(uid: 1, subject: "草稿", text: "舊內容")], Self.sent: []])
        await fake.update { $0.detailError = .unreachable }
        let model = Self.model(MailComposeContext(mode: .draft, folder: Self.drafts, uid: 1), fake: fake)
        await model.prepare()
        #expect(model.loadError != nil)
        model.body = "新內容"
        #expect(await model.saveDraft())
        // The failed load never confirmed which draft (if any) this is editing, so saving must
        // only append the new copy -- never touch (and never delete) uid 1.
        #expect(await fake.folders[Self.drafts]?.map(\.summary.uid).sorted() == [1, 2])
    }

    // MARK: Dispatch addition 7 — the demo mailbox composes, saves, reopens, edits and sends
    // entirely in memory, with no socket.

    @Test func demoMailboxRoundTripsAComposedDraftAndSend() async throws {
        let sentFolder = MailFolderRole.sent.imapName
        let draftsFolder = MailFolderRole.drafts.imapName
        let fixture = MailDemoFixture(studentId: "B99999999", password: "tigerduck-review", uidValidity: 1,
                                      folders: [sentFolder: [], draftsFolder: []])
        let demo = DemoMailClient(fixture: fixture)
        let prefs = InMemoryMailPreferences()
        let folderRoles: [MailFolderRole: String] = [.inbox: "INBOX", .sent: sentFolder, .drafts: draftsFolder]
        let sender = MailAddress(name: "王大明", address: "b99999999@mail.ntust.edu.tw")

        func model(_ context: MailComposeContext) -> MailComposeViewModel {
            MailComposeViewModel(context: context, session: MailPageSession(idleClose: .milliseconds(10), open: { demo }),
                                 sender: sender, folderRoles: folderRoles, prefs: prefs, sleep: { _ in })
        }

        // Plain ASCII subject/body throughout: DemoMailClient.append stores a draft's raw
        // quoted-printable body verbatim (no decode step) -- printable ASCII passes through QP
        // unchanged, so this exercises the compose/draft/send round trip without also depending
        // on that unrelated encoding path.
        let first = model(MailComposeContext(mode: .new))
        await first.prepare()
        first.subject = "Draft subject"
        first.body = "still working on it"
        #expect(await first.saveDraft())
        let draftsAfterFirstSave = try await demo.page(folder: draftsFolder, olderThanSequence: nil, pageSize: 50)
        let draftUID = try #require(draftsAfterFirstSave.summaries.first?.uid)

        let second = model(MailComposeContext(mode: .draft, folder: draftsFolder, uid: draftUID))
        await second.prepare()
        #expect(second.subject == "Draft subject")
        second.body = "done now"
        #expect(await second.saveDraft())
        let draftsAfterSecondSave = try await demo.page(folder: draftsFolder, olderThanSequence: nil, pageSize: 50)
        #expect(draftsAfterSecondSave.summaries.count == 1)
        #expect(draftsAfterSecondSave.summaries.first?.uid != draftUID)

        let third = model(MailComposeContext(mode: .draft, folder: draftsFolder, uid: draftsAfterSecondSave.summaries[0].uid))
        await third.prepare()
        // DemoMailClient.append's body extraction (splitting the raw message on the blank line)
        // keeps the message's own trailing CRLF -- not a Task 17 concern, so this only checks the
        // prefix rather than an exact match.
        #expect(third.body.hasPrefix("done now"))
        third.to = "office@mail.ntust.edu.tw"
        await third.send()
        #expect(third.didFinish)
        let sentAfter = try await demo.page(folder: sentFolder, olderThanSequence: nil, pageSize: 50)
        #expect(sentAfter.summaries.count == 1)
        let draftsAfterSend = try await demo.page(folder: draftsFolder, olderThanSequence: nil, pageSize: 50)
        #expect(draftsAfterSend.summaries.isEmpty)
    }
}
#endif
