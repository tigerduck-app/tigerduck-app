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

    static func model(_ context: MailComposeContext, fake: FakeMailClient, prefs: InMemoryMailPreferences = InMemoryMailPreferences(),
                      cache: MailCache = SchoolMailTestDoubles.temporaryCache()) -> MailComposeViewModel {
        MailComposeViewModel(
            context: context,
            // The session's auth-failure choke point, wired to the same preferences the compose
            // screen reads — in the app it is `MailAccountManager.handleAuthFailure()`, which
            // writes exactly this flag.
            session: MailPageSession(idleClose: .milliseconds(10), open: { fake },
                                     onAuthFailure: { prefs.authFailed = true }),
            sender: Self.me,
            folderRoles: [.inbox: "INBOX", .sent: Self.sent, .drafts: Self.drafts],
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

    /// §7.4: a password the server has rejected is never sent again — repeated failures lock the
    /// school account. SMTP `AUTH LOGIN` happens inside `send()`, entirely outside the sign-in
    /// path, so without routing it through the same choke point every Send tap is another login
    /// attempt with the rejected password.
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

        // §8.4 keeps the sheet open with the content intact, so the next tap is expected — and
        // must not reach the server.
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

    // A failed Reply-To fetch no longer fails the whole prefill (fix round 1, important 4 --
    // see `replyToFetchFailureIsBestEffortAndStillMarksAnswered` below), so this now uses a
    // draft load (`detail`) failure, the remaining realistic way `prepare()` can fail.
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
        // The failed load never confirmed which draft (if any) this is editing, so saving must
        // only append the new copy -- never touch (and never delete) uid 1.
        #expect(await fake.folders[Self.drafts]?.map(\.summary.uid).sorted() == [1, 2])
    }

    // MARK: Fix round 1

    // Important 4: everything a reply prefill needs is already in `context.original`, so a
    // failed Reply-To download must fall back to the sender's own address rather than emptying
    // the whole form, and threading/"mark answered" must still work.
    @Test func replyToFetchFailureIsBestEffortAndStillMarksAnswered() async {
        let fake = Self.fake()
        await fake.update { $0.rawSourceError = .unreachable }
        let model = Self.model(Self.originalContext(.reply), fake: fake)
        await model.prepare()
        #expect(model.loadError == nil)
        #expect(model.to == "林老師 <teacher@mail.ntust.edu.tw>")
        await model.send()
        #expect(await fake.calls.contains("setFlag answered true [3]"))
        let raw = String(decoding: await fake.sent.first?.message ?? Data(), as: UTF8.self)
        #expect(raw.contains("In-Reply-To: <m3@mail.ntust.edu.tw>"))
    }

    // Important 3: after a successful retry, an edit made before it must still count as unsaved
    // -- the baseline comes from the fresh prefill's own values, never from the fields as
    // merged with the user's kept edit.
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

    // Critical 1: without a cached page UIDVALIDITY for the drafts folder, the old-draft removal
    // must refuse outright -- never fall back to reading a fresh UIDVALIDITY right before
    // `MailMover`, which would make its own freshness guard compare a value against itself and
    // could never catch a folder recreated server-side. The refusal sends no command at all and
    // simply leaves the old copy behind (harmless: the new one already saved).
    @Test func draftReplacementRefusesWithoutACachedPageUIDValidity() async {
        let fake = FakeMailClient(folders: [Self.drafts: [FakeMailClient.message(uid: 1, subject: "草稿", text: "舊內容")], Self.sent: []])
        // No cache.savePage(...): the model's own `SchoolMailTestDoubles.temporaryCache()` default
        // has nothing cached for `drafts`, so `draftPageUIDValidity` stays nil.
        let model = Self.model(MailComposeContext(mode: .draft, folder: Self.drafts, uid: 1), fake: fake)
        await model.prepare()
        model.body = "新內容"
        #expect(await model.saveDraft())
        #expect(await !fake.calls.contains {
            $0.hasPrefix("status") || $0.hasPrefix("setFlag") || $0.hasPrefix("deletedUIDs") || $0.hasPrefix("expunge")
        })
        #expect(await fake.folders[Self.drafts]?.map(\.summary.uid).sorted() == [1, 2])
    }

    // MARK: Dispatch addition 7 — the demo mailbox composes, saves, reopens, edits and sends
    // entirely in memory, with no socket. Important 2 (fix round 1): a Chinese body and a
    // recipient both survive DemoMailClient's own append → detail round trip.

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
        // Mirrors the real list caching the page it just showed -- `removeDraft` needs this to
        // ever act (fix round 1, critical 1).
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

    // MARK: Fix round 2

    // Minor: a load that fails before ever prefilling anything must not leave the empty sheet
    // reporting unsaved changes.
    @Test func aFailedPrepareLeavesAnEmptySheetWithoutUnsavedChanges() async {
        let fake = FakeMailClient(folders: [Self.drafts: [FakeMailClient.message(uid: 1, subject: "草稿", text: "舊內容")], Self.sent: []])
        await fake.update { $0.detailError = .unreachable }
        let model = Self.model(MailComposeContext(mode: .draft, folder: Self.drafts, uid: 1), fake: fake)
        await model.prepare()
        #expect(model.loadError != nil)
        #expect(!model.hasChanges)
    }

    // Important: `readBounded(read:)` is `MailComposeView`'s bounded picked-file read (fix round
    // 1), seamed on a `FileHandle.read(upToCount:)`-shaped closure so these run without touching
    // the filesystem. A thrown mid-read error must fail the whole read, never silently return
    // whatever was read so far as if it had cleanly reached EOF (fix round 2, important) --
    // `Data(contentsOf:)`'s pre-round-1 behavior routed a failed read to `attachmentReadFailed()`
    // this way, and the bounded read must keep doing the same.
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
    // MARK: Edits made while a send or save is in flight

    /// `saveDraft` used to set `baseline = snapshot()` *after* the APPEND returned, reading the
    /// fields as they were then — so anything typed during the round trip was folded into the
    /// baseline, `hasChanges` reported clean for content the server does not have, and the leave
    /// dialog dismissed over it.
    @Test func textTypedWhileADraftIsSavingStaysUnsavedChanges() async {
        let fake = Self.fake()
        let model = Self.model(MailComposeContext(mode: .new), fake: fake)
        await model.prepare()
        model.to = "a@mail.ntust.edu.tw"
        model.body = "第一段"

        await fake.update { $0.hold("append") }
        let save = Task { await model.saveDraft() }
        await fake.waitForArrival("append")
        model.body = "第一段\n第二段"   // typed while the APPEND is still in flight
        await fake.release("append")

        #expect(await save.value)
        #expect(model.hasChanges) // the second line is not in what was appended
    }

    /// The same save with nothing typed during it must still come out clean, or the dialog would
    /// nag forever.
    @Test func aDraftSavedWithNoConcurrentEditsIsClean() async {
        let fake = Self.fake()
        let model = Self.model(MailComposeContext(mode: .new), fake: fake)
        await model.prepare()
        model.to = "a@mail.ntust.edu.tw"
        model.body = "第一段"
        #expect(await model.saveDraft())
        #expect(!model.hasChanges)
    }

    /// An attachment whose off-main read finishes after Send has already snapshotted the message
    /// would be listed on screen but in no mail the server ever saw. The view keeps this
    /// unreachable (Send is disabled while a pick is outstanding); the model refuses it anyway.
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

    // MARK: The send confirmation

    /// Validation runs first and confirmation second: a form 傳送 would reject gets the error it
    /// always got and no "要傳送這封信嗎？" — nobody is asked to confirm a send that was never
    /// going to happen. Fix the form and the question is worth asking.
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

    /// Cancelling the confirmation sends nothing and leaves the form intact — the model is only
    /// asked; nothing runs until the send itself is confirmed.
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

    /// A send already in flight can never have the question put over it a second time.
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

    // MARK: The error dialog

    /// Dismissing the dialog must not take the inline message with it, and the *same* failure
    /// happening again must raise the dialog again: tap 儲存草稿 with an unfinished 收件人,
    /// dismiss, change nothing, tap it again. `error` is a `String?`, so the second failure is
    /// character-for-character the first — anything that decided by comparing error values would
    /// see no change and leave the second tap looking like it did nothing at all.
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

    /// A send that succeeds leaves nothing to acknowledge.
    @Test func aSuccessfulSendRaisesNoDialog() async {
        let model = Self.model(MailComposeContext(mode: .new), fake: Self.fake())
        await model.prepare()
        model.to = "a@mail.ntust.edu.tw"
        await model.send()
        #expect(model.didFinish)
        #expect(model.error == nil)
        #expect(!model.errorNeedsAcknowledging)
    }
}
#endif
