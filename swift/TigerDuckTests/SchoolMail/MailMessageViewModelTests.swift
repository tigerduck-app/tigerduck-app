#if os(iOS)
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import TigerDuck

@MainActor
struct MailMessageViewModelTests {
    struct Harness {
        let model: MailMessageViewModel
        let fake: FakeMailClient
        let prefs: InMemoryMailPreferences
        let center: RecordingNotificationCenter
        let cache: MailCache
        let session: MailPageSession
        let folder: String

        @MainActor
        func anotherMessage(uid: UInt32) -> MailMessageViewModel {
            MailMessageViewModel(
                route: MailMessageRoute(folder: folder, uid: uid), session: session,
                folderRoles: [.inbox: "INBOX", .trash: MailMessageViewModelTests.trash],
                cache: cache, prefs: prefs, notifier: MailNotifier(center: RecordingNotificationCenter())
            )
        }
    }

    static let trash = MailFolderRole.trash.imapName

    static func harness(_ message: FakeMailClient.Message, folder: String = "INBOX", extra: [FakeMailClient.Message] = []) -> Harness {
        var folders: [String: [FakeMailClient.Message]] = [Self.trash: []]
        folders[folder] = [message] + extra
        let fake = FakeMailClient(folders: folders)
        let cache = SchoolMailTestDoubles.temporaryCache()
        cache.savePage(MailFolderPage(folder: folder, uidValidity: 1, messageCount: 1 + extra.count,
                                      summaries: ([message] + extra).map(\.summary), oldestLoadedSequence: nil))
        let prefs = InMemoryMailPreferences()
        prefs.inboxUIDValidity = 1
        let center = RecordingNotificationCenter()
        let session = MailPageSession(idleClose: .milliseconds(10), open: { fake })
        let model = MailMessageViewModel(
            route: MailMessageRoute(folder: folder, uid: message.summary.uid),
            session: session,
            folderRoles: [.inbox: "INBOX", .trash: Self.trash],
            cache: cache, prefs: prefs, notifier: MailNotifier(center: center)
        )
        return Harness(model: model, fake: fake, prefs: prefs, center: center, cache: cache, session: session, folder: folder)
    }

    @Test func loadsSanitizedHTMLAndWarnings() async {
        let h = Self.harness(FakeMailClient.message(uid: 5, from: "admin@evil.example", subject: "您的信箱容量已滿",
                                                    text: "請立即驗證", html: "<p>hi</p><script>x()</script>"))
        await h.model.load()
        #expect(h.model.loadState == .loaded)
        #expect(h.model.sanitized?.html.contains("<script") == false)
        #expect(h.model.plainText == "請立即驗證")
        #expect(h.model.warnings.contains(.externalSender(address: "admin@evil.example")))
        #expect(h.model.warnings.contains(.passwordBait))
        #expect(await h.fake.detailsWithoutImages.isEmpty)
    }

    @Test func aReplyStartsFromTheOpenedMailsReplyTo() async {
        let h = Self.harness(FakeMailClient.message(uid: 5, from: "teacher@mail.ntust.edu.tw",
                                                    replyTo: "教務處 <office@mail.ntust.edu.tw>, b@x.tw"))
        await h.model.load()
        #expect(h.model.original?.replyTo?.map(\.address) == ["office@mail.ntust.edu.tw", "b@x.tw"])
    }

    @Test func aDetailWithoutItsHeaderSectionLeavesReplyToUnknown() async throws {
        let h = Self.harness(FakeMailClient.message(uid: 5, replyTo: nil))
        await h.model.load()
        let original = try #require(h.model.original)
        #expect(original.replyTo == nil)
    }

    @Test func plainTextMailKeepsItsLinks() async {
        let h = Self.harness(FakeMailClient.message(uid: 5, text: "See https://www.ntust.edu.tw/ now", html: nil))
        await h.model.load()
        #expect(h.model.availableModes == [.plain, .source])
        let links = h.model.linkedPlainText.runs.compactMap(\.link)
        #expect(links == [URL(string: "https://www.ntust.edu.tw/")!])
    }

    @Test func htmlOnlyMailGetsAPlainTextView() async {
        let h = Self.harness(FakeMailClient.message(uid: 5, text: nil, html: "<p>a</p><p>b</p>"))
        await h.model.load()
        #expect(h.model.plainText == "a\nb")
    }

    @Test func theHeaderComesFromTheCachedPageWithoutWaitingForTheBody() async {
        let h = Self.harness(FakeMailClient.message(uid: 5, name: "教務處", subject: "期末考公告"))
        await h.fake.update { $0.detailError = .unreachable }
        await h.model.load()
        #expect(h.model.detail == nil)
        #expect(h.model.summary?.subject == "期末考公告")
        #expect(h.model.summary?.fromName == "教務處")
        #expect(h.model.loadState == .failed(MailAccountManager.LoginError(MailClientError.unreachable).message))
    }

    @Test func theLoadedMessageSupersedesTheCachedRow() async {
        let h = Self.harness(FakeMailClient.message(uid: 7, seen: false))
        await h.model.load()
        #expect(h.model.summary?.isSeen == true)
    }

    @Test func aMailWithNoHTMLDoesNotOfferTheFormattedMode() async {
        let h = Self.harness(FakeMailClient.message(uid: 5, text: "只有純文字", html: nil))
        #expect(h.model.availableModes == MailMessageViewModel.ViewMode.allCases)
        await h.model.load()
        #expect(h.model.availableModes == [.plain, .source])
        #expect(h.model.mode == .plain)
    }

    @Test func aMailWithHTMLKeepsTheFormattedMode() async {
        let h = Self.harness(FakeMailClient.message(uid: 5, text: "純文字", html: "<p>hi</p>"))
        await h.model.load()
        #expect(h.model.availableModes == MailMessageViewModel.ViewMode.allCases)
        #expect(h.model.mode == .formatted)
    }

    @Test func lightModeIsOfferedOnlyForTheFormattedViewOfAnHTMLMail() async {
        let h = Self.harness(FakeMailClient.message(uid: 5, text: "純文字", html: "<p>hi</p>"))
        #expect(!h.model.offersLightMode)
        await h.model.load()
        #expect(h.model.offersLightMode)
        h.model.mode = .plain
        #expect(!h.model.offersLightMode)
        h.model.mode = .source
        #expect(!h.model.offersLightMode)
    }

    @Test func aPlainTextMailHasNoLightMode() async {
        let h = Self.harness(FakeMailClient.message(uid: 5, text: "只有純文字", html: nil))
        await h.model.load()
        #expect(!h.model.offersLightMode)
    }

    @Test func lightModeSwitchesThePageTheMailIsDrawnOn() async {
        let h = Self.harness(FakeMailClient.message(uid: 5, text: "純文字", html: "<p>hi</p>"))
        await h.model.load()
        #expect(h.model.htmlTheme == .app)
        h.model.viewsInLightMode = true
        #expect(h.model.htmlTheme == .light)
        h.model.viewsInLightMode = false
        #expect(h.model.htmlTheme == .app)
    }

    @Test func lightModeBelongsToOneScreen() async {
        let h = Self.harness(FakeMailClient.message(uid: 5, html: "<p>a</p>"),
                             extra: [FakeMailClient.message(uid: 6, html: "<p>b</p>")])
        await h.model.load()
        h.model.viewsInLightMode = true
        let next = h.anotherMessage(uid: 6)
        await next.load()
        #expect(!next.viewsInLightMode)
        #expect(next.htmlTheme == .app)
    }

    @Test func aMailThatSetsItsOwnColoursOpensOnWhitePaper() async {
        let h = Self.harness(FakeMailClient.message(uid: 5, html: ##"<p><font color="#333333">Hi</font></p>"##))
        await h.model.load()
        #expect(h.model.viewsInLightMode)
        #expect(h.model.htmlTheme == .light)
        #expect(h.model.formattedHTML == ##"<p><font color="#333333">Hi</font></p>"##)
        h.model.viewsInLightMode = false
        #expect(h.model.htmlTheme == .app)
        #expect(h.model.formattedHTML == ##"<p><font color="#959595">Hi</font></p>"##)
    }

    @Test func plainTextAndUnstyledMailStayOnTheAppsPage() async {
        for message in [FakeMailClient.message(uid: 5, text: "純文字", html: nil), FakeMailClient.message(uid: 5, html: "<p>hi</p>")] {
            let h = Self.harness(message)
            await h.model.load()
            #expect(!h.model.viewsInLightMode)
            #expect(h.model.htmlTheme == .app)
        }
    }

    @Test func theReadersChoiceOutlastsARefresh() async {
        let h = Self.harness(FakeMailClient.message(uid: 5, html: ##"<p style="color: #333333">Hi</p>"##))
        await h.model.load()
        #expect(h.model.viewsInLightMode)
        h.model.viewsInLightMode = false
        await h.model.load()
        #expect(!h.model.viewsInLightMode)
    }

    @Test func loadingImagesRedrawsThePageTheReaderIsOn() async {
        let h = Self.harness(FakeMailClient.message(uid: 5, html: ##"<p style="color: #333333">Hi <img src="https://x.example/a.png"></p>"##))
        await h.model.load()
        h.model.viewsInLightMode = false
        await h.model.loadImages()
        #expect(!h.model.viewsInLightMode)
        #expect(h.model.formattedHTML == ##"<p style="color: #959595">Hi <img src="https://x.example/a.png" /></p>"##)
    }

    @Test func cancellingTheCallerCancelsTheDetachedWork() async {
        let caller = Task {
            await MailMessageViewModel.detachedCancellably { () -> Bool in
                for _ in 0..<5_000 {
                    if Task.isCancelled { return true }
                    usleep(1_000)
                }
                return false
            }
        }
        caller.cancel()
        #expect(await caller.value)
    }

    @Test func aCancelledLoadAppliesNothing() async throws {
        let message = FakeMailClient.message(uid: 5, html: ##"<p style="color: #333333">Hi</p>"##)
        let h = Self.harness(message)
        h.cache.saveDetail(try #require(message.detail), folder: "INBOX", uidValidity: 1)
        let load = Task { await h.model.load() }
        load.cancel()
        await load.value
        #expect(h.model.detail == nil)
        #expect(h.model.pages == nil)
    }

    @Test func unreadableMailFallsBackToSource() async {
        let h = Self.harness(FakeMailClient.message(uid: 5, text: nil, html: nil))
        await h.model.load()
        #expect(h.model.parseFailed)
        #expect(h.model.mode == .source)
    }

    @Test func openingUnreadMailMarksItReadAndClearsItsNotification() async {
        let h = Self.harness(FakeMailClient.message(uid: 7, seen: false))
        var seenChanges: [(String, UInt32, Bool)] = []
        h.model.onSeenChanged = { seenChanges.append(($0, $1, $2)) }
        await h.model.load()
        #expect(await h.fake.calls.contains("setFlag seen true [7]"))
        #expect(seenChanges.map(\.0) == ["INBOX"])
        #expect(seenChanges.map(\.1) == [7])
        #expect(h.center.removed == ["school-mail-1-7"])
    }

    @Test func aBounceAsksAboutTheTypoAndIsNotBadgedAsOutsideMail() async {
        let h = Self.harness(FakeMailClient.message(
            uid: 5, from: "", name: "Mail Deliver System",
            subject: "Returned Mail: Hostname cannot be resolved",
            text: "B10000001@mail.ntust.edj.tw [Hostname cannot be resolved]",
            returnPath: "<>"
        ))
        await h.model.load()
        #expect(h.model.warnings == [.mistypedRecipient])
        #expect(h.model.summary?.isExternal == false)
    }

    @Test func largeSourceLoadsWithoutAsking() async {
        var message = FakeMailClient.message(uid: 5)
        message.summary.size = 10 * 1024 * 1024
        let h = Self.harness(message)
        await h.model.load()
        await h.model.loadSource()
        #expect(h.model.source?.contains("Subject:") == true)
    }

    @Test func aLoadedSourceIsCachedAndServedFromTheCacheNextTime() async {
        let h = Self.harness(FakeMailClient.message(uid: 5))
        await h.model.load()
        await h.model.loadSource()
        let first = h.model.source
        #expect(first?.contains("Subject:") == true)
        #expect(await h.fake.calls.filter { $0 == "rawSource INBOX 5" }.count == 1)

        let again = h.anotherMessage(uid: 5)
        await again.load()
        await again.loadSource()
        #expect(again.source == first)
        #expect(await h.fake.calls.filter { $0 == "rawSource INBOX 5" }.count == 1)
    }

    @Test func aSourceFetchAfterAFolderRecreationIsRefused() async {
        let h = Self.harness(FakeMailClient.message(uid: 5))
        await h.model.load()
        await h.fake.update { $0.uidValidity["INBOX"] = 2 }
        await h.model.loadSource()
        #expect(h.model.source == nil)
        #expect(h.model.sourceLoadFailed)
        #expect(h.cache.loadSource(folder: "INBOX", uidValidity: 1, uid: 5) == nil)
    }

    @Test func aBodyOnTheWireWhenTheCacheIsWipedIsNotSaved() async {
        let h = Self.harness(FakeMailClient.message(uid: 5))
        await h.fake.hold("detail")
        let load = Task { await h.model.load() }
        await h.fake.waitForArrival("detail")
        h.cache.clearAll()
        await h.fake.release("detail")
        await load.value

        #expect(h.model.loadState == .loaded)
        #expect(h.cache.loadDetail(folder: "INBOX", uidValidity: 1, uid: 5) == nil)
    }

    @Test func aSourceOnTheWireWhenTheCacheIsWipedIsNotSaved() async {
        let h = Self.harness(FakeMailClient.message(uid: 5))
        await h.model.load()
        await h.fake.hold("rawSource")
        let load = Task { await h.model.loadSource() }
        await h.fake.waitForArrival("rawSource")
        h.cache.clearAll()
        await h.fake.release("rawSource")
        await load.value

        #expect(h.model.source?.contains("Subject:") == true)
        #expect(h.cache.loadSource(folder: "INBOX", uidValidity: 1, uid: 5) == nil)
    }

    @Test func aFailedSourceLoadEndsTheSpinnerWithARetryableFailedState() async {
        let h = Self.harness(FakeMailClient.message(uid: 5))
        await h.model.load()
        await h.fake.update { $0.rawSourceError = .unreachable }
        await h.model.loadSource()
        #expect(h.model.source == nil)
        #expect(h.model.sourceLoadFailed)
        #expect(h.model.actionError != nil)
        await h.fake.update { $0.rawSourceError = nil }
        await h.model.loadSource()
        #expect(h.model.source?.contains("Subject:") == true)
        #expect(!h.model.sourceLoadFailed)
    }

    @Test func movingToTrashRemovesItFromTheList() async {
        let h = Self.harness(FakeMailClient.message(uid: 5))
        var removed: [(String, UInt32)] = []
        h.model.onRemoved = { removed.append(($0, $1)) }
        await h.model.load()
        #expect(!h.model.deleteIsPermanent)
        #expect(await h.model.delete())
        #expect(removed.map(\.0) == ["INBOX"])
        #expect(removed.map(\.1) == [5])
        #expect(await h.fake.folders[Self.trash]?.count == 1)
    }

    @Test func pendingDeletionsAreRememberedWhenOthersFlaggedMailToo() async {
        let h = Self.harness(FakeMailClient.message(uid: 5), extra: [FakeMailClient.message(uid: 9, deleted: true)])
        await h.model.load()
        #expect(await h.model.move(to: Self.trash))
        #expect(h.prefs.ownedDeleted(folder: "INBOX", uidValidity: 1).uids == [5])
    }

    @Test func aPartlyFailedDeleteClaimsTheFlagItLandedInsteadOfWedgingTheFolder() async {
        let h = Self.harness(FakeMailClient.message(uid: 5), folder: Self.trash,
                             extra: [FakeMailClient.message(uid: 6)])
        await h.model.load()
        await h.fake.update { $0.deletedUIDsError = .serverBusy }
        #expect(await h.model.delete() == false)
        #expect(h.model.actionError != nil)
        #expect(await h.fake.folders[Self.trash]?.first(where: { $0.summary.uid == 5 })?.summary.isDeleted == true)
        #expect(h.prefs.ownedDeleted(folder: Self.trash, uidValidity: 1).uids == [5])

        await h.fake.update { $0.deletedUIDsError = nil }
        let second = h.anotherMessage(uid: 6)
        await second.load()
        #expect(await second.delete())
        #expect(await h.fake.folders[Self.trash]?.isEmpty == true)
    }

    @Test func aPartlyFailedDeleteNeverClaimsMailSomeoneElseHadAlreadyDeleted() async {
        let h = Self.harness(FakeMailClient.message(uid: 5, deleted: true), folder: Self.trash)
        await h.model.load()
        await h.fake.update { $0.deletedUIDsError = .serverBusy }
        #expect(await h.model.delete() == false)
        #expect(h.prefs.ownedDeleted(folder: Self.trash, uidValidity: 1).uids.isEmpty)
    }

    @Test func aDeleteRejectedForAuthenticationNeverFiresTheOwnershipProbe() async {
        let h = Self.harness(FakeMailClient.message(uid: 5), folder: Self.trash)
        await h.model.load()
        await h.fake.update { $0.setFlagError = .authenticationFailed }
        #expect(await h.model.delete() == false)
        #expect(!(await h.fake.calls).contains { $0.hasPrefix("flags ") })
    }

    @Test func aSecondTapDuringAMoveIsIgnoredInsteadOfFilingTheMailTwice() async {
        let h = Self.harness(FakeMailClient.message(uid: 5))
        await h.model.load()
        await h.fake.hold("copy")
        let first = Task { await h.model.move(to: Self.trash) }
        await h.fake.waitForArrival("copy")
        let second = Task { await h.model.move(to: Self.trash) }
        await Task.yield()
        await h.fake.release("copy")
        #expect(await first.value)
        #expect(await second.value == false)
        #expect(!h.model.isMoving)
        #expect((await h.fake.calls).filter { $0.hasPrefix("copy ") }.count == 1)
        #expect(await h.fake.folders[Self.trash]?.count == 1)
    }

    @Test func deletingInsideTrashIsPermanent() async {
        let h = Self.harness(FakeMailClient.message(uid: 5), folder: Self.trash)
        await h.model.load()
        #expect(h.model.deleteIsPermanent)
    }

    @Test func folderChangedShowsAnErrorAndNotifiesTheListToRecover() async {
        let h = Self.harness(FakeMailClient.message(uid: 5))
        await h.model.load()
        await h.fake.update { $0.uidValidity["INBOX"] = 2 }
        var removed: [(String, UInt32)] = []
        var changedFolders: [String] = []
        h.model.onRemoved = { removed.append(($0, $1)) }
        h.model.onFolderChanged = { changedFolders.append($0) }
        #expect(await h.model.move(to: Self.trash) == false)
        #expect(h.model.actionError != nil)
        #expect(removed.isEmpty)
        #expect(changedFolders == ["INBOX"])
    }

    @Test func toggleSeenFolderChangedNotifiesTheListToRecover() async {
        let h = Self.harness(FakeMailClient.message(uid: 5))
        await h.model.load()
        await h.fake.update { $0.setFlagError = .folderChanged }
        var changedFolders: [String] = []
        h.model.onFolderChanged = { changedFolders.append($0) }
        await h.model.toggleSeen()
        #expect(h.model.actionError != nil)
        #expect(changedFolders == ["INBOX"])
    }

    @Test func loadFolderChangedFromMarkAsSeenNotifiesTheListToRecover() async {
        let h = Self.harness(FakeMailClient.message(uid: 5, seen: false))
        var changedFolders: [String] = []
        h.model.onFolderChanged = { changedFolders.append($0) }
        await h.fake.update { $0.setFlagError = .folderChanged }
        await h.model.load()
        #expect(changedFolders == ["INBOX"])
        #expect(h.model.detail != nil)
        #expect(h.model.actionError != nil)
    }

    @Test func aDetailFetchAfterAFolderRecreationRecoversInsteadOfShowingAnotherMessage() async {
        let h = Self.harness(FakeMailClient.message(uid: 5, subject: "原信"))
        var changedFolders: [String] = []
        h.model.onFolderChanged = { changedFolders.append($0) }
        await h.fake.update { $0.uidValidity["INBOX"] = 2 }
        await h.model.load()

        #expect(h.model.detail == nil)
        #expect(changedFolders == ["INBOX"])
        #expect(h.model.loadState == .failed(MailAccountManager.LoginError(MailClientError.folderChanged).message))
        #expect(h.cache.loadDetail(folder: "INBOX", uidValidity: 1, uid: 5) == nil)
    }

    @Test func aNotificationFromBeforeAFolderRecreationDoesNotOpenTheMailNowAtItsUID() async {
        let h = Self.harness(FakeMailClient.message(uid: 5, subject: "新信"))
        await h.fake.update { $0.uidValidity["INBOX"] = 2 }
        h.cache.savePage(MailFolderPage(folder: "INBOX", uidValidity: 2, messageCount: 1,
                                        summaries: [FakeMailClient.message(uid: 5, subject: "新信").summary],
                                        oldestLoadedSequence: nil))
        let model = MailMessageViewModel(
            route: MailMessageRoute(folder: "INBOX", uid: 5, uidValidity: 1), session: h.session,
            folderRoles: [.inbox: "INBOX", .trash: Self.trash],
            cache: h.cache, prefs: h.prefs, notifier: MailNotifier(center: h.center)
        )
        await model.load()

        #expect(model.detail == nil)
        #expect(model.cachedSummary == nil)
        #expect(model.loadState == .failed(MailAccountManager.LoginError(MailClientError.folderChanged).message))
        #expect(await !h.fake.calls.contains { $0.hasPrefix("setFlag") })
    }

    @Test func anAlreadySeenMailIsPinnedTooEvenThoughItSetsNoFlag() async {
        let h = Self.harness(FakeMailClient.message(uid: 5, subject: "原信", seen: true))
        await h.fake.update { $0.uidValidity["INBOX"] = 2 }
        await h.model.load()

        let calls = await h.fake.calls
        #expect(h.model.detail == nil)
        #expect(!calls.contains { $0.hasPrefix("setFlag") })
        #expect(h.model.loadState == .failed(MailAccountManager.LoginError(MailClientError.folderChanged).message))
    }

    @Test func movingWithNoCachedPageValidityRefusesInsteadOfGuessing() async {
        let h = Self.harness(FakeMailClient.message(uid: 5))
        #expect(await h.model.move(to: Self.trash) == false)
        #expect(h.model.actionError != nil)
        #expect(await h.fake.calls.isEmpty)
    }

    @Test func aFailedRefreshWhenAlreadyLoadedSetsAnActionError() async {
        let h = Self.harness(FakeMailClient.message(uid: 5))
        await h.model.load()
        #expect(h.model.actionError == nil)
        await h.fake.update { $0.detailError = .unreachable }
        await h.model.load()
        #expect(h.model.actionError != nil)
        #expect(h.model.detail != nil)
    }

    @Test func attachmentsAreWrittenToATemporaryFile() async throws {
        let part = MailBodyPart(section: "2", contentType: "application/pdf", charset: nil, transferEncoding: "base64",
                                filename: "課程.pdf", contentID: nil, size: 4, isAttachment: true)
        var message = FakeMailClient.message(uid: 5)
        message.detail?.parts = [part]
        message.attachments = ["2": Data("%PDF".utf8)]
        let h = Self.harness(message)
        await h.model.load()
        let url = try #require(await h.model.prepareAttachment(part))
        #expect(url.lastPathComponent == "課程.pdf")
        #expect(try Data(contentsOf: url) == Data("%PDF".utf8))
        #expect(!h.model.isRisky(part))
        #expect(await h.fake.attachmentPins == [1])
    }

    @Test func aRepeatTapDuringAnAttachmentDownloadIsIgnored() async {
        let part = MailBodyPart(section: "2", contentType: "application/pdf", charset: nil, transferEncoding: "base64",
                                filename: "課程.pdf", contentID: nil, size: 4, isAttachment: true)
        var message = FakeMailClient.message(uid: 5)
        message.detail?.parts = [part]
        message.attachments = ["2": Data("%PDF".utf8)]
        let h = Self.harness(message)
        await h.model.load()
        await h.fake.hold("attachment")
        let first = Task { await h.model.prepareAttachment(part) }
        await h.fake.waitForArrival("attachment")
        #expect(h.model.downloading == ["2"])
        let second = Task { await h.model.prepareAttachment(part) }
        await Task.yield()
        await h.fake.release("attachment")
        #expect(await first.value != nil)
        #expect(await second.value == nil)
        #expect(h.model.downloading.isEmpty)
        #expect((await h.fake.calls).filter { $0.hasPrefix("attachment ") }.count == 1)
    }

    @Test func anAttachmentDownloadRefusesAfterTheFolderWasRecreated() async {
        let part = MailBodyPart(section: "2", contentType: "application/pdf", charset: nil, transferEncoding: "base64",
                                filename: "課程.pdf", contentID: nil, size: 4, isAttachment: true)
        var message = FakeMailClient.message(uid: 5)
        message.detail?.parts = [part]
        message.attachments = ["2": Data("%PDF".utf8)]
        let h = Self.harness(message)
        await h.model.load()
        await h.fake.update { $0.uidValidity["INBOX"] = 2 }
        #expect(await h.model.prepareAttachment(part) == nil)
        #expect(h.model.actionError == MailAccountManager.LoginError(MailClientError.folderChanged).message)
        #expect(await h.fake.attachmentPins == [1])
        #expect(h.model.downloading.isEmpty)
    }

    @Test func htmlContentTypeAttachmentIsRiskyAndNeverRenderedInApp() async {
        let part = MailBodyPart(section: "2", contentType: "text/html; charset=utf-8", charset: nil, transferEncoding: nil,
                                filename: "notes.txt", contentID: nil, size: 4, isAttachment: true)
        var message = FakeMailClient.message(uid: 5)
        message.detail?.parts = [part]
        let h = Self.harness(message)
        await h.model.load()
        #expect(h.model.isRisky(part))
        #expect(h.model.isNeverRenderedInApp(part))
    }

    @Test func svgContentTypeWithParametersIsAlsoNeverRenderedInApp() async {
        let part = MailBodyPart(section: "2", contentType: "image/svg+xml; charset=utf-8", charset: nil, transferEncoding: nil,
                                filename: "diagram", contentID: nil, size: 4, isAttachment: true)
        var message = FakeMailClient.message(uid: 5)
        message.detail?.parts = [part]
        let h = Self.harness(message)
        await h.model.load()
        #expect(h.model.isRisky(part))
        #expect(h.model.isNeverRenderedInApp(part))
    }

    @Test func doubleExtensionAttachmentIsRiskyButNotForcedToShare() async {
        let part = MailBodyPart(section: "2", contentType: "application/octet-stream", charset: nil, transferEncoding: nil,
                                filename: "invoice.pdf.exe", contentID: nil, size: 4, isAttachment: true)
        var message = FakeMailClient.message(uid: 5)
        message.detail?.parts = [part]
        let h = Self.harness(message)
        await h.model.load()
        #expect(h.model.isRisky(part))
        #expect(!h.model.isNeverRenderedInApp(part))
    }

    @Test func linkChecksUseTheAnchorTextAndCanonicalizeTheHref() async {
        let h = Self.harness(FakeMailClient.message(uid: 5, html: "<a href=\"https://ntust-login.xyz/r\">ntust.edu.tw</a>"))
        await h.model.load()
        let target = h.model.linkTarget(forIndex: 0)
        #expect(target?.href == "https://ntust-login.xyz/r")
        #expect(target?.canOpen == true)
        #expect(target?.issues == [.mismatch(shownHost: "ntust.edu.tw", realHost: "ntust-login.xyz")])
    }

    @Test func theRewrittenDocumentAddressesLinksByIndexNotURL() async {
        let h = Self.harness(FakeMailClient.message(uid: 5, html: "<a href=\"https://a.example\">a</a><a href=\"https://b.example\">b</a>"))
        await h.model.load()
        #expect(h.model.linkedDocument?.html.contains(#"href="https://link.invalid/0""#) == true)
        #expect(h.model.linkedDocument?.html.contains(#"href="https://link.invalid/1""#) == true)
        #expect(h.model.linkedDocument?.html.contains("a.example") == false)
        #expect(h.model.linkTarget(forIndex: 1)?.href == "https://b.example/")
    }

    @Test func anOutOfRangeLinkIndexReturnsNil() async {
        let h = Self.harness(FakeMailClient.message(uid: 5, html: "<a href=\"https://a.example\">a</a>"))
        await h.model.load()
        #expect(h.model.linkTarget(forIndex: 1) == nil)
        #expect(h.model.linkTarget(forIndex: -1) == nil)
    }

    /// The href judged, shown and opened is canonicalized once the way a browser would: a
    /// backslash after the scheme is a separator, so the authority ends at "evil.example" and
    /// the "last `@` ends userinfo" rule never even reaches "ntust.edu.tw" hiding after it.
    @Test func canonicalizationFoldsABackslashBeforeReadingUserinfo() async {
        let h = Self.harness(Self.messageWithRawLinkHref(#"https://evil.example\@ntust.edu.tw/login"#))
        await h.model.load()
        let target = h.model.linkTarget(forIndex: 0)
        #expect(target?.href == "https://evil.example/@ntust.edu.tw/login")
        #expect(target?.issues.contains { issue in
            if case .mismatch(let shown, let real) = issue { return shown == "ntust.edu.tw" && real == "evil.example" }
            return false
        } == true)
    }

    @Test func canonicalizationPreservesExistingPercentEncoding() async {
        let h = Self.harness(FakeMailClient.message(
            uid: 5,
            html: "<a href=\"https://sso.example/go?u=https%3A%2F%2Fntust.edu.tw%2Fpath%23frag&amp;x=a%26b\">ntust.edu.tw</a>"
        ))
        await h.model.load()
        let target = h.model.linkTarget(forIndex: 0)
        #expect(target?.href == "https://sso.example/go?u=https%3A%2F%2Fntust.edu.tw%2Fpath%23frag&x=a%26b")
    }

    @Test func canonicalizationUppercasesAMixedCaseEscapeWithoutDecodingIt() async {
        let h = Self.harness(Self.messageWithRawLinkHref("https://a.example/x%2fy"))
        await h.model.load()
        #expect(h.model.linkTarget(forIndex: 0)?.href == "https://a.example/x%2Fy")
    }

    @Test func linkTargetForPlainTextChecksTheURLDirectly() async {
        let h = Self.harness(FakeMailClient.message(uid: 5, text: "See http://evil.example/", html: nil))
        await h.model.load()
        let target = h.model.linkTarget(forPlainText: URL(string: "http://evil.example/")!)
        #expect(target.href == "http://evil.example/")
        #expect(target.canOpen)
        #expect(target.issues == [.insecure])
    }

    @Test func loadingImagesReSanitizes() async {
        let h = Self.harness(FakeMailClient.message(uid: 5, html: "<img src=\"https://x.example/a.png\">"))
        await h.model.load()
        #expect(h.model.sanitized?.blockedRemoteImages == 1)
        await h.model.loadImages()
        #expect(h.model.allowRemoteImages)
        #expect(h.model.sanitized?.blockedRemoteImages == 0)
    }

    @Test func concurrentLoadAndLoadImagesNeverLeaveInconsistentState() async {
        let h = Self.harness(FakeMailClient.message(uid: 5, html: "<img src=\"https://x.example/a.png\">"))
        await h.model.load()
        #expect(h.model.sanitized?.blockedRemoteImages == 1)
        async let reload: Void = h.model.load()
        async let images: Void = h.model.loadImages()
        _ = await (reload, images)
        #expect(h.model.allowRemoteImages)
        #expect(h.model.sanitized != nil)
    }

    @Test func theWebViewIsLockedDown() {
        let configuration = MailWebViewFactory.makeConfiguration(cidHandler: MailCIDSchemeHandler(images: [:]))
        #expect(configuration.defaultWebpagePreferences.allowsContentJavaScript == false)
        #expect(!configuration.websiteDataStore.isPersistent)
        #expect(configuration.urlSchemeHandler(forURLScheme: MailHTMLSanitizer.cidScheme) != nil)
        #expect(configuration.dataDetectorTypes == [])
    }

    @Test func contentRulesBlockEverythingButInlineImages() {
        let blocked = MailWebViewFactory.contentRules(allowRemoteImages: false)
        #expect(blocked.contains("\"type\":\"block\""))
        #expect(blocked.contains("^tdcid:"))
        #expect(!blocked.contains("\"resource-type\""))
        #expect(MailWebViewFactory.contentRules(allowRemoteImages: true).contains("\"resource-type\":[\"image\"]"))
    }

    @Test func theDocumentCarriesACSP() {
        let blocked = MailWebViewFactory.document(for: "<p>x</p>", allowRemoteImages: false)
        #expect(blocked.contains("default-src 'none'; img-src tdcid: data:; style-src 'unsafe-inline'"))
        #expect(MailWebViewFactory.document(for: "", allowRemoteImages: true).contains("img-src tdcid: data: https: http:"))
    }

    @Test func theDocumentIsDrawnOnTheAppsPage() {
        let document = MailWebViewFactory.document(for: "<p>x</p>", allowRemoteImages: false)
        #expect(document.contains("background:#000000"))
        #expect(document.contains("color:#ffffff"))
        #expect(document.contains(":root{color-scheme:dark;}"))
        #expect(!document.contains("#ffffff;color:#000000"))
    }

    @Test func aLightThemeSaysSo() {
        let light = MailHTMLTheme(background: 0xFFFFFF, foreground: 0x1A1A1A, link: 0x0000EE, isDark: false)
        let document = MailWebViewFactory.document(for: "", allowRemoteImages: false, theme: light)
        #expect(document.contains("color-scheme:light"))
        #expect(document.contains("background:#ffffff;color:#1a1a1a"))
    }

    @Test func lightModeIsWhitePaper() {
        let document = MailWebViewFactory.document(for: "<p>x</p>", allowRemoteImages: false, theme: .light)
        #expect(document.contains(":root{color-scheme:light;}"))
        #expect(document.contains("background:#ffffff;color:#000000"))
    }

    @Test func aLightModeSwitchReusesTheInstalledRules() async {
        var view = MailHTMLView(html: "<p>x</p>", linkCount: 0, inlineImages: [:], allowRemoteImages: false,
                                contentHeight: .constant(1), onLinkTap: { _ in })
        let coordinator = view.makeCoordinator()
        let webView = WKWebView(frame: .zero, configuration: MailWebViewFactory.makeConfiguration(cidHandler: coordinator.cidHandler))
        coordinator.load(into: webView)
        await coordinator.loadTask?.value
        #expect(coordinator.installedRulesAllowRemoteImages == false)

        view.theme = .light
        coordinator.parent = view
        coordinator.load(into: webView)
        #expect(coordinator.loadTask == nil)
        #expect(webView.scrollView.backgroundColor == MailHTMLTheme.light.backgroundColor)

        var withImages = MailHTMLView(html: "<p>x</p>", linkCount: 0, inlineImages: [:], allowRemoteImages: true,
                                      contentHeight: .constant(1), onLinkTap: { _ in })
        withImages.theme = .light
        coordinator.parent = withImages
        coordinator.load(into: webView)
        #expect(coordinator.loadTask != nil)
        await coordinator.loadTask?.value
        #expect(coordinator.installedRulesAllowRemoteImages == true)
    }

    @Test func inlineImagesThatArriveLaterReachThePage() async {
        let html = #"<p><img src="tdcid:logo"></p>"#
        let cached = MailHTMLView(html: html, linkCount: 0, inlineImages: [:], allowRemoteImages: false,
                                  contentHeight: .constant(1), onLinkTap: { _ in })
        let coordinator = cached.makeCoordinator()
        let webView = WKWebView(frame: .zero, configuration: MailWebViewFactory.makeConfiguration(cidHandler: coordinator.cidHandler))
        coordinator.load(into: webView)
        await coordinator.loadTask?.value
        let cachedLoad = coordinator.loadedKey

        let logo = MailInlineImage(mimeType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]))
        coordinator.parent = MailHTMLView(html: html, linkCount: 0, inlineImages: ["logo": logo], allowRemoteImages: false,
                                          contentHeight: .constant(1), onLinkTap: { _ in })
        coordinator.load(into: webView)

        #expect(coordinator.cidHandler.images["logo"] == logo)
        #expect(coordinator.loadedKey != cachedLoad)
    }

    @Test func aSendersOwnColoursAreLeftAlone() {
        let body = #"<p style="background:#ffeeaa;color:#003300">x</p>"#
        #expect(MailWebViewFactory.document(for: body, allowRemoteImages: false).contains(body))
    }

    @Test func themeColoursAreSixDigitHex() {
        #expect(MailHTMLTheme.css(0x00_0A_0B) == "#000a0b")
        #expect(MailHTMLTheme.css(0xFF_12_34_56) == "#123456")
    }

    @Test func aNamedSenderGetsTwoLines() {
        let lines = MailMessageView.senderLines(name: "教務處", address: "office@mail.ntust.edu.tw")
        #expect(lines.primary == "教務處")
        #expect(lines.secondary == "office@mail.ntust.edu.tw")
    }

    @Test func aSenderWithNoNameShowsTheAddressOnce() {
        let lines = MailMessageView.senderLines(name: nil, address: "someone@gmail.com")
        #expect(lines.primary == "someone@gmail.com")
        #expect(lines.secondary == nil)
        let blank = MailMessageView.senderLines(name: "   ", address: "someone@gmail.com")
        #expect(blank.primary == "someone@gmail.com")
        #expect(blank.secondary == nil)
    }

    @Test func aMissingAddressLeavesNoEmptyLine() {
        let bounce = MailMessageView.senderLines(name: "Mail Deliver System", address: "")
        #expect(bounce.primary == "Mail Deliver System")
        #expect(bounce.secondary == nil)
        let nothing = MailMessageView.senderLines(name: nil, address: " ")
        #expect(nothing.primary == nil)
        #expect(nothing.secondary == nil)
    }

    @Test func recipientsAreReadIntoNameAndAddress() {
        let list = MailRecipient.parse(["\"王大明\" <a@mail.ntust.edu.tw>", " ", "b@gmail.com", "undisclosed-recipients:"],
                                       ownAddress: nil)
        #expect(list.count == 3)
        #expect(list[0].name == "王大明")
        #expect(list[0].address == "a@mail.ntust.edu.tw")
        #expect(list[1].name == nil)
        #expect(list[1].address == "b@gmail.com")
        #expect(list[2].address == nil)
        #expect(list[2].raw == "undisclosed-recipients:")
        #expect(MailRecipient.parse(nil, ownAddress: nil).isEmpty)
    }

    @Test func theStudentsOwnAddressIsMarked() {
        let list = MailRecipient.parse(["B10000000@Mail.NTUST.edu.tw", "b10000001@mail.ntust.edu.tw"],
                                       ownAddress: "b10000000@mail.ntust.edu.tw")
        #expect(list.map(\.isSelf) == [true, false])
        #expect(MailRecipient.parse(["a@x.com"], ownAddress: nil).map(\.isSelf) == [false])
    }

    @Test func theFieldLabelIsTheLocalizedPrefix() {
        #expect(MailMessageView.fieldLabel("school_mail_details_to")
            == String(format: String(localized: "school_mail_details_to"), "").trimmingCharacters(in: .whitespaces))
        #expect(!MailMessageView.fieldLabel("school_mail_details_cc").contains("%"))
    }

    @Test func linkIndexParsingAcceptsOnlyTheExactSyntheticForm() {
        #expect(MailWebViewFactory.parseLinkIndex("https://link.invalid/0", linkCount: 2) == 0)
        #expect(MailWebViewFactory.parseLinkIndex("https://link.invalid/1", linkCount: 2) == 1)
        #expect(MailWebViewFactory.parseLinkIndex("https://link.invalid/2", linkCount: 2) == nil)
        #expect(MailWebViewFactory.parseLinkIndex("https://link.invalid/01", linkCount: 2) == nil)
        #expect(MailWebViewFactory.parseLinkIndex("https://link.invalid/0?x=1", linkCount: 2) == nil)
        #expect(MailWebViewFactory.parseLinkIndex("https://link.invalid.evil/0", linkCount: 2) == nil)
        // ICU's `$` also matches immediately before a trailing line terminator, unlike a strict
        // end-of-string anchor.
        #expect(MailWebViewFactory.parseLinkIndex("https://link.invalid/0\n", linkCount: 2) == nil)
    }

    private static func messageWithRawLinkHref(_ href: String) -> FakeMailClient.Message {
        FakeMailClient.message(uid: 5, html: "<a href=\"\(href)\">ntust.edu.tw</a>")
    }
    @Test func thePlainViewIsBuiltFromTheSanitizedDocumentNotTheRawBody() async {
        let html = "<p>正常內容</p><noscript>您的信箱容量已滿，請立即驗證 https://evil.example/login</noscript>"
        let h = Self.harness(FakeMailClient.message(uid: 5, text: nil, html: html))
        await h.model.load()
        #expect(h.model.plainText.contains("正常內容"))
        #expect(!h.model.plainText.contains("evil.example"))
        #expect(!h.model.plainText.contains("信箱容量已滿"))
    }
}
#endif
