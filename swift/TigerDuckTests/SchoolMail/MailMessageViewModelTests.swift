#if os(iOS)
import Foundation
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

        /// A second screen over the same fake server, cache, prefs and connection — what the user
        /// gets by going back to the list and opening another mail.
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
    }

    @Test func htmlOnlyMailGetsAPlainTextView() async {
        let h = Self.harness(FakeMailClient.message(uid: 5, text: nil, html: "<p>a</p><p>b</p>"))
        await h.model.load()
        #expect(h.model.plainText == "a\nb")
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

    @Test func largeSourceAsksFirst() async {
        var message = FakeMailClient.message(uid: 5)
        message.summary.size = MailConstants.sourceConfirmBytes + 1
        let h = Self.harness(message)
        await h.model.load()
        await h.model.loadSource()
        #expect(h.model.needsSourceConfirmation)
        #expect(h.model.source == nil)
        await h.model.loadSource(confirmed: true)
        #expect(h.model.source?.contains("Subject:") == true)
    }

    /// A failed source load must end the spinner in a terminal, retryable state rather than
    /// spinning forever (fix round 1, minor 6).
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

    // `MailPreferences` has no `ownDeletedUIDs` (message-screen dispatch, 2026-09-16 addition
    // 3): the owned-deleted set is keyed by folder AND the UIDVALIDITY the page was built from.
    @Test func pendingDeletionsAreRememberedWhenOthersFlaggedMailToo() async {
        let h = Self.harness(FakeMailClient.message(uid: 5), extra: [FakeMailClient.message(uid: 9, deleted: true)])
        await h.model.load()
        #expect(await h.model.move(to: Self.trash))
        #expect(h.prefs.ownedDeleted(folder: "INBOX", uidValidity: 1).uids == [5])
    }

    /// A delete whose STORE lands but whose deleted-UID check then fails leaves a `\Deleted` UID
    /// on the server. If the app does not claim it, `shouldExpunge` is false in that folder for
    /// good: every later delete degrades to "hide", and 回收筒 stops actually deleting anything.
    @Test func aPartlyFailedDeleteClaimsTheFlagItLandedInsteadOfWedgingTheFolder() async {
        let h = Self.harness(FakeMailClient.message(uid: 5), folder: Self.trash,
                             extra: [FakeMailClient.message(uid: 6)])
        await h.model.load()
        await h.fake.update { $0.deletedUIDsError = .serverBusy }
        #expect(await h.model.delete() == false)
        #expect(h.model.actionError != nil)
        // The STORE reached the server, so the flag is ours and has to be remembered.
        #expect(await h.fake.folders[Self.trash]?.first(where: { $0.summary.uid == 5 })?.summary.isDeleted == true)
        #expect(h.prefs.ownedDeleted(folder: Self.trash, uidValidity: 1).uids == [5])

        // ...and because it is remembered, the next delete in that folder still expunges.
        await h.fake.update { $0.deletedUIDsError = nil }
        let second = h.anotherMessage(uid: 6)
        await second.load()
        #expect(await second.delete())
        #expect(await h.fake.folders[Self.trash]?.isEmpty == true)
    }

    /// A message another client had already flagged `\Deleted` must never become ours just
    /// because our own STORE also touched it.
    @Test func aPartlyFailedDeleteNeverClaimsMailSomeoneElseHadAlreadyDeleted() async {
        let h = Self.harness(FakeMailClient.message(uid: 5, deleted: true), folder: Self.trash)
        await h.model.load()
        await h.fake.update { $0.deletedUIDsError = .serverBusy }
        #expect(await h.model.delete() == false)
        #expect(h.prefs.ownedDeleted(folder: Self.trash, uidValidity: 1).uids.isEmpty)
    }

    /// The credentials or the connection that just failed are exactly what the ownership probe
    /// would need, so it must not fire a second, doomed request after either.
    @Test func aDeleteRejectedForAuthenticationNeverFiresTheOwnershipProbe() async {
        let h = Self.harness(FakeMailClient.message(uid: 5), folder: Self.trash)
        await h.model.load()
        await h.fake.update { $0.setFlagError = .authenticationFailed }
        #expect(await h.model.delete() == false)
        #expect(!(await h.fake.calls).contains { $0.hasPrefix("flags ") })
    }

    /// Move and delete are four to five round trips with no progress indication, so a second tap
    /// is expected behaviour. It must not COPY the mail a second time — that files one message
    /// into two folders — nor race the owned-deleted read-modify-write.
    @Test func aSecondTapDuringAMoveIsIgnoredInsteadOfFilingTheMailTwice() async {
        let h = Self.harness(FakeMailClient.message(uid: 5))
        await h.model.load()
        await h.fake.hold("copy")
        let first = Task { await h.model.move(to: Self.trash) }
        // The first COPY is on the wire; the screen shows no progress, so the user taps again.
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

    /// A move that hits `folderChanged` shows the error and reports the folder through
    /// `onFolderChanged` — never a bare `cache.dropFolder` of its own, which could race and be
    /// undone by the list's queued cache-write chain (fix round 1, important 2).
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

    /// `setFlag` (not just `MailMover`) can also hit `folderChanged`; `toggleSeen` must notify
    /// the list the same way `performMove` does (fix round 2, minor 4).
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

    /// The mark-as-seen `setFlag` inside `load()` can also hit `folderChanged` (fix round 2,
    /// minor 4); the detail fetch itself already succeeded by then, so this exercises the
    /// "cached/fresh detail already showing" branch of the catch (fix round 1, minor 7) with a
    /// `folderChanged` specifically, not a generic error.
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

    /// Without a cached page UIDVALIDITY there is nothing honest to compare a move against —
    /// fetching one fresh right there would make `MailMover`'s freshness check compare a value
    /// against itself. Refuses instead, with no server call at all (fix round 1, minor 8).
    @Test func movingWithNoCachedPageValidityRefusesInsteadOfGuessing() async {
        let h = Self.harness(FakeMailClient.message(uid: 5))
        // No `load()` call: `pageUIDValidity` is never populated.
        #expect(await h.model.move(to: Self.trash) == false)
        #expect(h.model.actionError != nil)
        #expect(await h.fake.calls.isEmpty)
    }

    /// A cached detail can already be on screen when a background refresh (or the mark-as-seen
    /// that follows it) fails; that must still surface, not be silently swallowed just because
    /// something is already showing (fix round 1, minor 7).
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
    }

    /// Mirrors Android's `SchoolMailMessageViewModel.needsConfirmation`: a `text/html` or
    /// `image/svg+xml` attachment is risky regardless of its filename extension — AND, unlike a
    /// merely risky file, is one Quick Look must never render in-process (fix round 1, critical
    /// 1: `isNeverRenderedInApp` is the predicate that forces the share-sheet path even for a
    /// confirmed "open"). A real part's content type carries parameters (`; charset=…`) —
    /// fix round 2's leftover: comparing the whole string was inert against exactly this shape,
    /// so the fixture must carry one too, not a bare `"text/html"` the round-1 test used.
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

    /// The other branch of critical 1: a merely risky attachment (a dangerous extension
    /// disguised behind a decoy one) is NOT forced to the share sheet — "resume the requested
    /// action" still applies to it, only never-rendered-in-app types are forced.
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

    // MARK: Links — index-based (message-screen dispatch, 2026-09-16 addition 1: links are
    // addressed by index into the rewritten document's own anchors, never by URL matching).

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

    /// The href judged, shown and opened is canonicalized once the way a browser would
    /// (dispatch addition 2): a backslash after the scheme is a separator, so the authority
    /// ends at "evil.example" and the "last `@` ends userinfo" rule never even reaches
    /// "ntust.edu.tw" hiding after it.
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

    /// Canonicalization never percent-decodes (fix round 1, important 3): a redirect/safelink
    /// URL's own `%2F`/`%23`/nested-percent-encoded-URL shape must survive exactly, or the href
    /// shown and opened stops meaning what the sender's href actually meant.
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

    /// `loadImages` moved off the main actor alongside `apply` (fix round 2, minor 3), both now
    /// guarded by the same generation token (minor 2) so neither can clobber a result the other
    /// already applied. Concurrent calls must never leave `allowRemoteImages` and
    /// `sanitized.blockedRemoteImages` disagreeing with each other.
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

    // MARK: Web view lockdown (§9.3)

    @Test func theWebViewIsLockedDown() {
        let configuration = MailWebViewFactory.makeConfiguration(inlineImages: [:])
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

    @Test func linkIndexParsingAcceptsOnlyTheExactSyntheticForm() {
        #expect(MailWebViewFactory.parseLinkIndex("https://link.invalid/0", linkCount: 2) == 0)
        #expect(MailWebViewFactory.parseLinkIndex("https://link.invalid/1", linkCount: 2) == 1)
        #expect(MailWebViewFactory.parseLinkIndex("https://link.invalid/2", linkCount: 2) == nil)
        #expect(MailWebViewFactory.parseLinkIndex("https://link.invalid/01", linkCount: 2) == nil)
        #expect(MailWebViewFactory.parseLinkIndex("https://link.invalid/0?x=1", linkCount: 2) == nil)
        #expect(MailWebViewFactory.parseLinkIndex("https://link.invalid.evil/0", linkCount: 2) == nil)
        // Fix round 1, minor 10: ICU's `$` also matches immediately before a trailing line
        // terminator, unlike a strict end-of-string anchor.
        #expect(MailWebViewFactory.parseLinkIndex("https://link.invalid/0\n", linkCount: 2) == nil)
    }

    // MARK: Helpers

    /// A message whose HTML body's single anchor carries `href` verbatim — used for
    /// canonicalization test cases whose href isn't representable as a normal Swift string
    /// interpolation inside an HTML literal (backslashes, etc.).
    private static func messageWithRawLinkHref(_ href: String) -> FakeMailClient.Message {
        FakeMailClient.message(uid: 5, html: "<a href=\"\(href)\">ntust.edu.tw</a>")
    }
    /// Android builds the plain view from the sanitized document; iOS built it from the raw
    /// body, so text the sanitizer drops with its container was invisible in the formatted view
    /// and visible — and linkified — in the plain one. Two views of one mail saying different
    /// things is a usable bait-and-switch, and the hidden text also fed the password-bait
    /// keyword haystack.
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
