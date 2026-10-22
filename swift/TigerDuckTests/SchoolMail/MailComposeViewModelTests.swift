#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct MailComposeViewModelTests {
    static let me = MailAddress(name: "王大明", address: "b10000000@mail.ntust.edu.tw")
    /// `nonisolated` because the fake-server `update` closures below are nonisolated, and the
    /// suite is `@MainActor` — without it this constant is main-actor isolated and reading it
    /// from one of those closures is an error in the Swift 6 language mode. `MailFolderRole` is
    /// `nonisolated` already, so the value has nothing main-actor about it.
    nonisolated static let sent = MailFolderRole.sent.imapName
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

    static func model(_ context: MailComposeContext, fake: FakeMailClient, prefs: InMemoryMailPreferences = InMemoryMailPreferences(),
                      cache: MailCache = SchoolMailTestDoubles.temporaryCache(),
                      roles: [MailFolderRole: String]? = nil) -> MailComposeViewModel {
        MailComposeViewModel(
            context: context,
            session: MailPageSession(idleClose: .milliseconds(10), open: { fake },
                                     onAuthFailure: { prefs.authFailed = true }),
            sender: Self.me,
            folderRoles: roles ?? [.inbox: "INBOX", .sent: Self.sent, .drafts: Self.drafts],
            prefs: prefs,
            cache: cache,
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
            subject: "作業", date: message.summary.date, messageID: "<m3@mail.ntust.edu.tw>", references: [], bodyText: "請繳交",
            replyTo: [MailAddress(name: nil, address: "office@mail.ntust.edu.tw")]
        )
        return MailComposeContext(mode: mode, folder: "INBOX", uid: 3, original: original,
                                  attachments: mode == .forward ? message.detail?.parts ?? [] : [])
    }

    @Test func replyGoesToReplyToWithAQuotedBody() async {
        let fake = Self.fake()
        let model = Self.model(Self.originalContext(.reply), fake: fake)
        await model.prepare()
        #expect(model.to == "office@mail.ntust.edu.tw")
        #expect(await !fake.calls.contains { $0.hasPrefix("rawSource") })
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
        let fake = Self.fake()
        let cache = SchoolMailTestDoubles.temporaryCache()
        cache.savePage(MailFolderPage(folder: "INBOX", uidValidity: 1, messageCount: 1, summaries: [], oldestLoadedSequence: nil))
        let model = Self.model(Self.originalContext(.forward), fake: fake, cache: cache)
        await model.prepare()
        #expect(model.subject == "Fwd: 作業")
        #expect(model.attachments.map(\.filename) == ["作業說明.pdf"])
        #expect(model.to.isEmpty)
        #expect(await fake.attachmentPins == [1])
    }

    @Test func forwardRefusesAttachmentsFromARecreatedFolder() async {
        let fake = Self.fake()
        await fake.update { $0.uidValidity["INBOX"] = 2 }
        let cache = SchoolMailTestDoubles.temporaryCache()
        cache.savePage(MailFolderPage(folder: "INBOX", uidValidity: 1, messageCount: 1, summaries: [], oldestLoadedSequence: nil))
        let model = Self.model(Self.originalContext(.forward), fake: fake, cache: cache)
        await model.prepare()
        #expect(await fake.attachmentPins == [1])
        #expect(model.loadError == MailAccountManager.LoginError(MailClientError.folderChanged).message)
        #expect(model.attachments.isEmpty)
    }

    @Test func aDraftsAttachmentsAreFetchedUnderTheSamePinAsItsDetail() async {
        var draft = FakeMailClient.message(uid: 1, subject: "草稿", text: "附件在這")
        let part = MailBodyPart(section: "2", contentType: "application/pdf", charset: nil, transferEncoding: "base64",
                                filename: "附件.pdf", contentID: nil, size: 4, isAttachment: true)
        draft.detail?.parts = [part]
        draft.attachments = ["2": Data("%PDF".utf8)]
        let drafts = Self.drafts
        let fake = FakeMailClient(folders: [drafts: [draft], Self.sent: []])
        await fake.update { $0.uidValidity[drafts] = 7 }
        let cache = SchoolMailTestDoubles.temporaryCache()
        cache.savePage(MailFolderPage(folder: Self.drafts, uidValidity: 7, messageCount: 1, summaries: [], oldestLoadedSequence: nil))
        let model = Self.model(MailComposeContext(mode: .draft, folder: Self.drafts, uid: 1), fake: fake, cache: cache)
        await model.prepare()
        #expect(model.attachments.map(\.filename) == ["附件.pdf"])
        #expect(await fake.attachmentPins == [7])
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
        #expect(model.sentCopy == .serverFiledItself)
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
        let cache = SchoolMailTestDoubles.temporaryCache()
        cache.savePage(MailFolderPage(folder: Self.drafts, uidValidity: 1, messageCount: 1, summaries: [], oldestLoadedSequence: nil))
        let model = Self.model(MailComposeContext(mode: .draft, folder: Self.drafts, uid: 1), fake: fake, cache: cache)
        await model.prepare()
        #expect(model.subject == "草稿")
        #expect(model.body == "舊內容")
        model.body = "新內容"
        #expect(await model.saveDraft())
        #expect(await fake.folders[Self.drafts]?.map(\.summary.uid) == [2])
    }

    @Test func reopeningADraftRestoresItsAttachments() async {
        var draft = FakeMailClient.message(uid: 1, subject: "草稿", text: "附件在這")
        let part = MailBodyPart(section: "2", contentType: "application/pdf", charset: nil, transferEncoding: "base64",
                                filename: "附件.pdf", contentID: nil, size: 4, isAttachment: true)
        draft.detail?.parts = [part]
        draft.attachments = ["2": Data("%PDF".utf8)]
        let fake = FakeMailClient(folders: [Self.drafts: [draft], Self.sent: []])
        let model = Self.model(MailComposeContext(mode: .draft, folder: Self.drafts, uid: 1), fake: fake)
        await model.prepare()
        #expect(model.attachments.map(\.filename) == ["附件.pdf"])
        #expect(model.attachments.first?.data == Data("%PDF".utf8))
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

    @Test func anUnconfirmedSendSaysItMayHaveGone() async {
        let fake = Self.fake()
        await fake.update { $0.sendError = .sendUnconfirmed }
        let model = Self.model(MailComposeContext(mode: .new), fake: fake)
        await model.prepare()
        model.to = "a@mail.ntust.edu.tw"
        model.subject = "問題"
        await model.send()
        #expect(model.error == String(localized: "school_mail_send_unconfirmed"))
        #expect(!model.didFinish)
    }

    @Test func aRejectedSMTPPasswordIsRecordedAndNeverRetried() async {
        let fake = Self.fake()
        await fake.update { $0.sendError = .authenticationFailed }
        let prefs = InMemoryMailPreferences()
        let model = Self.model(MailComposeContext(mode: .new), fake: fake, prefs: prefs)
        await model.prepare()
        model.to = "a@mail.ntust.edu.tw"
        model.subject = "問題"

        await model.send()
        #expect(model.error != nil)
        #expect(!model.didFinish)
        #expect(prefs.authFailed)

        await model.send()
        #expect((await fake.calls).filter { $0 == "send" }.count == 1)
        #expect(model.subject == "問題")
    }

    @Test func sendRefusesOutrightWhileTheSavedPasswordIsKnownRejected() async {
        let fake = Self.fake()
        let prefs = InMemoryMailPreferences()
        prefs.authFailed = true
        let model = Self.model(MailComposeContext(mode: .new), fake: fake, prefs: prefs)
        await model.prepare()
        model.to = "a@mail.ntust.edu.tw"
        await model.send()
        #expect(model.error != nil)
        #expect(await fake.calls.isEmpty)
        #expect(!model.didFinish)
    }

    @Test func savingADraftAlsoRefusesWhileTheSavedPasswordIsKnownRejected() async {
        let fake = Self.fake()
        let prefs = InMemoryMailPreferences()
        prefs.authFailed = true
        let model = Self.model(MailComposeContext(mode: .new), fake: fake, prefs: prefs)
        await model.prepare()
        model.body = "草稿"
        #expect(await model.saveDraft() == false)
        #expect(await fake.calls.isEmpty)
    }

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

    @Test func retryPrepareKeepsTypedTextAndPickedAttachmentsAfterAFailure() async {
        let fake = FakeMailClient(folders: [Self.drafts: [FakeMailClient.message(uid: 1, subject: "草稿", text: "舊內容")], Self.sent: []])
        await fake.update { $0.detailError = .unreachable }
        let cache = SchoolMailTestDoubles.temporaryCache()
        cache.savePage(MailFolderPage(folder: Self.drafts, uidValidity: 1, messageCount: 1, summaries: [], oldestLoadedSequence: nil))
        let model = Self.model(MailComposeContext(mode: .draft, folder: Self.drafts, uid: 1), fake: fake, cache: cache)
        await model.prepare()
        #expect(model.loadError != nil)
        model.body = "還在寫"
        model.addAttachment(filename: "note.txt", mimeType: "text/plain", data: Data("hi".utf8))
        await fake.update { $0.detailError = nil }
        await model.retryPrepare()
        #expect(model.loadError == nil)
        #expect(model.subject == "草稿")
        #expect(model.body == "還在寫")
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
        #expect(await fake.folders[Self.drafts]?.map(\.summary.uid).sorted() == [1, 2])
    }

    @Test func aReplyWithoutReplyToGoesToTheSenderAndMarksAnswered() async {
        let fake = Self.fake()
        var context = Self.originalContext(.reply)
        context.original?.replyTo = []
        let model = Self.model(context, fake: fake)
        await model.prepare()
        #expect(model.loadError == nil)
        #expect(model.to == "林老師 <teacher@mail.ntust.edu.tw>")
        #expect(await !fake.calls.contains { $0.hasPrefix("rawSource") })
        await model.send()
        #expect(await fake.calls.contains("setFlag answered true [3]"))
        let raw = String(decoding: await fake.sent.first?.message ?? Data(), as: UTF8.self)
        #expect(raw.contains("In-Reply-To: <m3@mail.ntust.edu.tw>"))
    }

    @Test func anUnknownReplyToIsReadFromTheRawMessage() async {
        let fake = Self.fake()
        var context = Self.originalContext(.reply)
        context.original?.replyTo = nil
        let model = Self.model(context, fake: fake)
        await model.prepare()
        #expect(model.to == "office@mail.ntust.edu.tw")
        #expect(await fake.calls.contains("rawSource INBOX 3"))
    }

    @Test func anUnknownReplyToIsNeverReadFromAnotherGeneration() async {
        let fake = Self.fake()
        await fake.update { $0.uidValidity["INBOX"] = 2 }
        let cache = SchoolMailTestDoubles.temporaryCache()
        cache.savePage(MailFolderPage(folder: "INBOX", uidValidity: 1, messageCount: 1, summaries: [], oldestLoadedSequence: nil))
        var context = Self.originalContext(.reply)
        context.original?.replyTo = nil
        let model = Self.model(context, fake: fake, cache: cache)
        await model.prepare()
        #expect(await fake.calls.contains("rawSource INBOX 3"))
        #expect(model.to == "林老師 <teacher@mail.ntust.edu.tw>")
    }

    @Test func aFailedReplyToDownloadAnswersTheSender() async {
        let fake = Self.fake()
        await fake.update { $0.rawSourceError = .unreachable }
        var context = Self.originalContext(.reply)
        context.original?.replyTo = nil
        let model = Self.model(context, fake: fake)
        await model.prepare()
        #expect(model.loadError == nil)
        #expect(model.to == "林老師 <teacher@mail.ntust.edu.tw>")
        #expect(model.subject == "Re: 作業")
    }

    @Test func aSuccessfulRetryKeepsTheUsersEditCountingAsAnUnsavedChange() async {
        let fake = FakeMailClient(folders: [Self.drafts: [FakeMailClient.message(uid: 1, subject: "草稿", text: "舊內容")], Self.sent: []])
        await fake.update { $0.detailError = .unreachable }
        let cache = SchoolMailTestDoubles.temporaryCache()
        cache.savePage(MailFolderPage(folder: Self.drafts, uidValidity: 1, messageCount: 1, summaries: [], oldestLoadedSequence: nil))
        let model = Self.model(MailComposeContext(mode: .draft, folder: Self.drafts, uid: 1), fake: fake, cache: cache)
        await model.prepare()
        #expect(model.loadError != nil)
        model.subject = "使用者改的主旨"
        await fake.update { $0.detailError = nil }
        await model.retryPrepare()
        #expect(model.loadError == nil)
        #expect(model.subject == "使用者改的主旨")
        #expect(model.hasChanges)
    }

    @Test func draftReplacementRefusesWithoutACachedPageUIDValidity() async {
        let fake = FakeMailClient(folders: [Self.drafts: [FakeMailClient.message(uid: 1, subject: "草稿", text: "舊內容")], Self.sent: []])
        let model = Self.model(MailComposeContext(mode: .draft, folder: Self.drafts, uid: 1), fake: fake)
        await model.prepare()
        model.body = "新內容"
        #expect(await model.saveDraft())
        #expect(await !fake.calls.contains {
            $0.hasPrefix("status") || $0.hasPrefix("setFlag") || $0.hasPrefix("deletedUIDs") || $0.hasPrefix("expunge")
        })
        #expect(await fake.folders[Self.drafts]?.map(\.summary.uid).sorted() == [1, 2])
    }

    @Test func demoMailboxRoundTripsAComposedDraftAndSend() async throws {
        let sentFolder = MailFolderRole.sent.imapName
        let draftsFolder = MailFolderRole.drafts.imapName
        let fixture = MailDemoFixture(studentId: "B99999999", password: "tigerduck-review", uidValidity: 1,
                                      folders: [sentFolder: [], draftsFolder: []])
        let demo = DemoMailClient(fixture: fixture)
        let prefs = InMemoryMailPreferences()
        let cache = SchoolMailTestDoubles.temporaryCache()
        let folderRoles: [MailFolderRole: String] = [.inbox: "INBOX", .sent: sentFolder, .drafts: draftsFolder]
        let sender = MailAddress(name: "王大明", address: "b99999999@mail.ntust.edu.tw")

        func model(_ context: MailComposeContext) -> MailComposeViewModel {
            MailComposeViewModel(context: context, session: MailPageSession(idleClose: .milliseconds(10), open: { demo }),
                                 sender: sender, folderRoles: folderRoles, prefs: prefs, cache: cache, sleep: { _ in })
        }

        let first = model(MailComposeContext(mode: .new))
        await first.prepare()
        first.to = "office@mail.ntust.edu.tw"
        first.subject = "草稿主旨"
        first.body = "還沒寫完，晚點再改"
        #expect(await first.saveDraft())
        let draftsAfterFirstSave = try await demo.page(folder: draftsFolder, olderThanSequence: nil, pageSize: 50)
        let draftUID = try #require(draftsAfterFirstSave.summaries.first?.uid)
        cache.savePage(MailFolderPage(folder: draftsFolder, uidValidity: fixture.uidValidity, messageCount: 1,
                                      summaries: draftsAfterFirstSave.summaries, oldestLoadedSequence: nil))

        let second = model(MailComposeContext(mode: .draft, folder: draftsFolder, uid: draftUID))
        await second.prepare()
        #expect(second.subject == "草稿主旨")
        #expect(second.body == "還沒寫完，晚點再改")
        #expect(second.to == "office@mail.ntust.edu.tw")
        second.body = "改好了，可以寄出"
        #expect(await second.saveDraft())
        let draftsAfterSecondSave = try await demo.page(folder: draftsFolder, olderThanSequence: nil, pageSize: 50)
        #expect(draftsAfterSecondSave.summaries.count == 1)
        #expect(draftsAfterSecondSave.summaries.first?.uid != draftUID)
        cache.savePage(MailFolderPage(folder: draftsFolder, uidValidity: fixture.uidValidity, messageCount: 1,
                                      summaries: draftsAfterSecondSave.summaries, oldestLoadedSequence: nil))

        let third = model(MailComposeContext(mode: .draft, folder: draftsFolder, uid: draftsAfterSecondSave.summaries[0].uid))
        await third.prepare()
        #expect(third.body == "改好了，可以寄出")
        #expect(third.to == "office@mail.ntust.edu.tw")
        await third.send()
        #expect(third.didFinish)
        let sentAfter = try await demo.page(folder: sentFolder, olderThanSequence: nil, pageSize: 50)
        #expect(sentAfter.summaries.count == 1)
        let draftsAfterSend = try await demo.page(folder: draftsFolder, olderThanSequence: nil, pageSize: 50)
        #expect(draftsAfterSend.summaries.isEmpty)
    }

    @Test func aFailedPrepareLeavesAnEmptySheetWithoutUnsavedChanges() async {
        let fake = FakeMailClient(folders: [Self.drafts: [FakeMailClient.message(uid: 1, subject: "草稿", text: "舊內容")], Self.sent: []])
        await fake.update { $0.detailError = .unreachable }
        let model = Self.model(MailComposeContext(mode: .draft, folder: Self.drafts, uid: 1), fake: fake)
        await model.prepare()
        #expect(model.loadError != nil)
        #expect(!model.hasChanges)
    }

    @Test func readBoundedFailsOnAThrownMidReadErrorRatherThanTruncating() {
        struct ReadFailure: Error {}
        var calls = 0
        let result = MailComposeView.readBounded { _ in
            calls += 1
            if calls == 1 { return Data("first chunk, then the read breaks".utf8) }
            throw ReadFailure()
        }
        #expect(result == nil)
    }

    @Test func readBoundedReturnsEverythingReadThroughACleanEOF() {
        let chunks: [Data?] = [Data("hello ".utf8), Data("world".utf8), nil]
        var index = 0
        let result = MailComposeView.readBounded { _ in
            defer { index += 1 }
            return index < chunks.count ? chunks[index] : nil
        }
        #expect(result == Data("hello world".utf8))
    }

    @Test func readBoundedRejectsOnceThePastLimitChunkArrivesEvenWithoutAThrow() {
        let oversized = Data(count: MailConstants.maxEncodedMessageBytes + 1)
        var served = false
        let result = MailComposeView.readBounded { _ in
            defer { served = true }
            return served ? nil : oversized
        }
        #expect(result == nil)
    }

    @Test func textTypedWhileADraftIsSavingStaysUnsavedChanges() async {
        let fake = Self.fake()
        let model = Self.model(MailComposeContext(mode: .new), fake: fake)
        await model.prepare()
        model.to = "a@mail.ntust.edu.tw"
        model.body = "第一段"

        await fake.update { $0.hold("append") }
        let save = Task { await model.saveDraft() }
        await fake.waitForArrival("append")
        model.body = "第一段\n第二段"
        await fake.release("append")

        #expect(await save.value)
        #expect(model.hasChanges)
    }

    @Test func aDraftSavedWithNoConcurrentEditsIsClean() async {
        let fake = Self.fake()
        let model = Self.model(MailComposeContext(mode: .new), fake: fake)
        await model.prepare()
        model.to = "a@mail.ntust.edu.tw"
        model.body = "第一段"
        #expect(await model.saveDraft())
        #expect(!model.hasChanges)
    }

    @Test func anAttachmentArrivingDuringASendIsRefused() async {
        let fake = Self.fake()
        let model = Self.model(MailComposeContext(mode: .new), fake: fake)
        await model.prepare()
        model.to = "a@mail.ntust.edu.tw"

        await fake.update { $0.hold("send") }
        let send = Task { await model.send() }
        await fake.waitForArrival("send")
        model.addAttachment(filename: "late.pdf", mimeType: "application/pdf", data: Data("%PDF".utf8))
        #expect(model.attachments.isEmpty)
        await fake.release("send")
        await send.value
        #expect(model.didFinish)
    }

    @Test func aFormThatFailsValidationIsNeverConfirmed() async {
        let model = Self.model(MailComposeContext(mode: .new), fake: Self.fake())
        await model.prepare()

        #expect(!model.confirmationIsWarranted())
        #expect(model.error != nil)
        #expect(model.errorNeedsAcknowledging)

        model.to = "沒有位址"
        #expect(!model.confirmationIsWarranted())
        #expect(model.invalidRecipients == ["沒有位址"])

        model.to = "a@mail.ntust.edu.tw"
        #expect(model.confirmationIsWarranted())
        #expect(model.error == nil)
    }

    @Test func cancellingTheConfirmationSendsNothing() async {
        let fake = Self.fake()
        let model = Self.model(MailComposeContext(mode: .new), fake: fake)
        await model.prepare()
        model.to = "a@mail.ntust.edu.tw"
        model.body = "還沒寫完"

        #expect(model.confirmationIsWarranted())
        #expect(await fake.sent.isEmpty)
        #expect(model.body == "還沒寫完")
        #expect(!model.didFinish)
    }

    @Test func aSendInFlightCannotBeConfirmedAgain() async {
        let fake = Self.fake()
        let model = Self.model(MailComposeContext(mode: .new), fake: fake)
        await model.prepare()
        model.to = "a@mail.ntust.edu.tw"

        await fake.update { $0.hold("send") }
        let send = Task { await model.send() }
        await fake.waitForArrival("send")
        #expect(!model.confirmationIsWarranted())
        await fake.release("send")
        await send.value
        #expect(model.didFinish)
    }

    @Test func repeatingTheSameFailureRaisesTheDialogAgain() async {
        let model = Self.model(MailComposeContext(mode: .new), fake: Self.fake())
        await model.prepare()
        model.to = "收件人還沒打完"
        model.body = "草稿"

        #expect(await !model.saveDraft())
        let first = model.error
        #expect(first != nil)
        #expect(model.errorNeedsAcknowledging)

        model.acknowledgeError()
        #expect(!model.errorNeedsAcknowledging)
        #expect(model.error == first)

        #expect(await !model.saveDraft())
        #expect(model.error == first)
        #expect(model.errorNeedsAcknowledging)
    }

    @Test func aSuccessfulSendRaisesNoDialog() async {
        let model = Self.model(MailComposeContext(mode: .new), fake: Self.fake())
        await model.prepare()
        model.to = "a@mail.ntust.edu.tw"
        await model.send()
        #expect(model.didFinish)
        #expect(model.error == nil)
        #expect(!model.errorNeedsAcknowledging)
    }

    @discardableResult
    static func sendCollectingNotice(_ model: MailComposeViewModel, to: String = "a@mail.ntust.edu.tw") async -> String? {
        var notice: String?
        model.onSentCopyNotice = { notice = $0 }
        await model.prepare()
        model.to = to
        await model.send()
        return notice
    }

    @Test func theProbeTellsFoundNotFoundAndUnknownApart() async throws {
        let fake = Self.fake()
        let messageID = "<probe@mail.ntust.edu.tw>"
        #expect(await SentCopyFiler.probe(messageID, in: Self.sent, client: fake).result == .notFound)

        try await fake.append(Data("Message-ID: \(messageID)\r\n\r\ncopy\r\n".utf8), to: Self.sent, flags: [.seen])
        #expect(await SentCopyFiler.probe(messageID, in: Self.sent, client: fake).result == .found)

        await fake.update { $0.containsMessageIDError = .searchUnsupported }
        let refused = await SentCopyFiler.probe(messageID, in: Self.sent, client: fake)
        #expect(refused.result == .unknown)
        #expect(refused.failure == .searchUnsupported)
    }

    @Test func aProbeTheServerRefusesFilesNothingRatherThanADuplicate() async {
        let fake = Self.fake()
        await fake.update {
            $0.containsMessageIDError = .searchUnsupported
            $0.autoSaveSentTo = Self.sent
        }
        let model = Self.model(MailComposeContext(mode: .new), fake: fake)
        let notice = await Self.sendCollectingNotice(model)

        #expect(model.didFinish)
        #expect(model.error == nil)
        #expect(model.sentCopy == .unknown)
        #expect(await !fake.calls.contains { $0.hasPrefix("append") })
        #expect(await fake.folders[Self.sent]?.count == 1)
        #expect(notice == MailComposeViewModel.notice(for: .unknown))
    }

    @Test func aFailedAppendStillReportsTheSendAsSuccessful() async {
        let fake = Self.fake()
        await fake.update { $0.appendError = .unreachable }
        let model = Self.model(MailComposeContext(mode: .new), fake: fake)
        let notice = await Self.sendCollectingNotice(model)

        #expect(model.didFinish)
        #expect(model.error == nil)
        #expect(!model.errorNeedsAcknowledging)
        #expect(model.sentCopy == .failed(.unreachable))
        #expect(await fake.sent.count == 1)
        #expect(notice != nil)
    }

    @Test func aRejectedPasswordFromTheSentCopyAppendReachesTheAccount() async {
        let fake = Self.fake()
        await fake.update { $0.appendError = .authenticationFailed }
        let prefs = InMemoryMailPreferences()
        let model = Self.model(MailComposeContext(mode: .new), fake: fake, prefs: prefs)
        await Self.sendCollectingNotice(model)

        #expect(model.didFinish)
        #expect(model.sentCopy == .failed(.authenticationFailed))
        #expect(prefs.authFailed)
    }

    @Test func aRejectedPasswordFromTheDedupeProbeAlsoReachesTheAccount() async {
        let fake = Self.fake()
        await fake.update { $0.containsMessageIDError = .authenticationFailed }
        let prefs = InMemoryMailPreferences()
        let model = Self.model(MailComposeContext(mode: .new), fake: fake, prefs: prefs)
        await Self.sendCollectingNotice(model)

        #expect(model.didFinish)
        #expect(model.sentCopy == .unknown)
        #expect(prefs.authFailed)
    }

    @Test func aSendWithNoSentFolderToFileIntoSaysSoWithoutFailing() async {
        let fake = FakeMailClient(folders: ["INBOX": [Self.original()], Self.drafts: []])
        await fake.update { $0.createFolderError = .protocolError("refused") }
        let model = Self.model(MailComposeContext(mode: .new), fake: fake,
                               roles: [.inbox: "INBOX", .drafts: Self.drafts])
        let notice = await Self.sendCollectingNotice(model)

        #expect(model.didFinish)
        #expect(model.error == nil)
        #expect(model.sentCopy == .notAttempted)
        #expect(await fake.sent.count == 1)
        #expect(notice == MailComposeViewModel.notice(for: .notAttempted))
    }

    @Test func onlyAnUnkeptCopyIsWorthANotice() {
        #expect(MailComposeViewModel.notice(for: .filed) == nil)
        #expect(MailComposeViewModel.notice(for: .serverFiledItself) == nil)
        let notices = [
            MailComposeViewModel.notice(for: .notAttempted),
            MailComposeViewModel.notice(for: .failed(.unreachable)),
            MailComposeViewModel.notice(for: .unknown),
        ]
        #expect(notices.allSatisfy { $0?.isEmpty == false })
        #expect(Set(notices.compactMap { $0 }).count == 3)
    }

    @Test func aFiledCopyRaisesNoNotice() async {
        let fake = Self.fake()
        let model = Self.model(MailComposeContext(mode: .new), fake: fake)
        let notice = await Self.sendCollectingNotice(model)
        #expect(model.sentCopy == .filed)
        #expect(notice == nil)
    }

    @Test func theDemoMailboxAnswersTheProbeFromItsOwnContents() async throws {
        let sentFolder = MailFolderRole.sent.imapName
        let fixture = MailDemoFixture(studentId: "B99999999", password: "tigerduck-review", uidValidity: 1,
                                      folders: [sentFolder: []])
        let demo = DemoMailClient(fixture: fixture)
        let messageID = "<demo-probe@mail.ntust.edu.tw>"
        #expect(await SentCopyFiler.probe(messageID, in: sentFolder, client: demo).result == .notFound)

        let mail = OutgoingMail(from: Self.me, to: [MailAddress(name: nil, address: "a@mail.ntust.edu.tw")], cc: [],
                                bcc: [], subject: "備份", body: "內容", inReplyTo: nil, references: [], attachments: [])
        try await demo.append(MailMessageBuilder.build(mail, messageID: messageID, date: Date()),
                              to: sentFolder, flags: [.seen])
        #expect(await SentCopyFiler.probe(messageID, in: sentFolder, client: demo).result == .found)
        #expect(await SentCopyFiler.probe("<someone-else@mail.ntust.edu.tw>", in: sentFolder, client: demo).result == .notFound)
    }
}
#endif
