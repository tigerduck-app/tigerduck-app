#if os(iOS)
import Foundation
import SwiftMail
import Testing
@testable import TigerDuck

@MainActor
struct MailRowActionsTests {
    nonisolated static let trash = MailFolderRole.trash.imapName
    nonisolated static let course = "Moodle &irJ6C4oOitZTQA-"

    struct Harness {
        let list: MailListViewModel
        let actions: MailRowActions
        let fake: FakeMailClient
        let cache: MailCache
        let account: AccountSession

        @MainActor
        func row(_ uid: UInt32) throws -> MailListRow {
            try #require(list.rows.first { $0.uid == uid })
        }
    }

    static func harness(withTrash: Bool = true, storesFlagged: Set<String>? = nil, loads: Bool = true) async -> Harness {
        var folders: [String: [FakeMailClient.Message]] = [
            "INBOX": (1...3).map { FakeMailClient.message(uid: $0, subject: "公告 \($0)", seen: $0 == 2) },
            course: [],
        ]
        if withTrash { folders[trash] = [FakeMailClient.message(uid: 1, subject: "舊信")] }
        let fake = FakeMailClient(folders: folders)
        await fake.update {
            $0.foldersStoringFlagged = storesFlagged
            $0.createFolderError = .protocolError("NO")
        }
        let cache = SchoolMailTestDoubles.temporaryCache()
        let account = AccountSession()
        let session = MailPageSession(idleClose: .milliseconds(10), open: { fake }, account: account)
        let list = MailListViewModel(session: session, account: account, cache: cache, noteSeenByPage: { _, _ in },
                                     signOutEvents: NotificationCenter(),
                                     warmDelay: { try? await Task.sleep(for: .seconds(86_400)) },
                                     catchUpDelay: { try? await Task.sleep(for: .seconds(86_400)) })
        let actions = MailRowActions(prefs: InMemoryMailPreferences(), notifier: MailNotifier(center: RecordingNotificationCenter()))
        if loads { await list.load() }
        return Harness(list: list, actions: actions, fake: fake, cache: cache, account: account)
    }

    @Test func aFullSwipeRunsTrashWhichSitsAtTheEdgeBesideFlagAndMore() {
        #expect(MailRowAction.trailing(canFlag: true) == [.trash, .toggleFlag, .more])
        #expect(MailRowAction.trailing(canFlag: false) == [.trash, .more])
    }

    @Test func flagIsOfferedWhereTheServerKeepsItAndAskedOncePerFolder() async throws {
        let h = await Self.harness()
        #expect(h.list.canFlag("INBOX"))
        await h.list.load()
        #expect(await h.fake.calls.filter { $0 == "storesFlagged INBOX" }.count == 1)
    }

    @Test func flagIsHiddenWhenTheFoldersPermanentFlagsLackIt() async throws {
        let h = await Self.harness(storesFlagged: [])
        #expect(!h.list.canFlag("INBOX"))
        #expect(await h.fake.calls.contains("storesFlagged INBOX"))
    }

    @Test func aFlagStorageAnswerThatArrivesAfterTheSignInEndsIsDropped() async throws {
        let h = await Self.harness(loads: false)
        await h.fake.holdNext("storesFlagged")
        let loading = Task { await h.list.load() }
        await h.fake.waitForArrival("storesFlagged")
        h.account.endSignIn()
        await h.fake.release("storesFlagged")
        await loading.value
        #expect(!h.list.canFlag("INBOX"))
    }

    @Test(arguments: [
        ([Flag.seen, .answered, .flagged, .deleted, .draft], true),
        ([Flag.seen, .custom("wildcard")], true),
        ([Flag.seen, .answered, .deleted, .draft], false),
        ([Flag](), false),
    ])
    func permanentFlagsDecideWhetherAFlagIsKept(flags: [Flag], kept: Bool) {
        #expect(MailIMAPCommands.storesFlagged(permanentFlags: flags) == kept)
    }

    @Test func flaggingMarksTheRowAndStoresTheFlagOnTheServer() async throws {
        let h = await Self.harness()
        await h.list.toggleFlag(try h.row(3))
        #expect(try h.row(3).summary.isFlagged)
        #expect(await h.fake.calls.contains("setFlag flagged true [3]"))
        #expect(await h.fake.folders["INBOX"]?.first { $0.summary.uid == 3 }?.summary.isFlagged == true)
        await h.list.waitForCacheWrites()
        #expect(h.cache.loadPage(folder: "INBOX")?.summaries.first { $0.uid == 3 }?.isFlagged == true)

        await h.list.toggleFlag(try h.row(3))
        #expect(try !h.row(3).summary.isFlagged)
        #expect(await h.fake.calls.contains("setFlag flagged false [3]"))
    }

    @Test func aRefusedFlagPutsTheRowBack() async throws {
        let h = await Self.harness()
        await h.fake.update { $0.setFlagError = .unreachable }
        await h.list.toggleFlag(try h.row(3))
        #expect(try !h.row(3).summary.isFlagged)
    }

    @Test func aFlagSetWhileARefreshIsInFlightOutlastsIt() async throws {
        let h = await Self.harness()
        let row = try h.row(3)
        await h.fake.holdNext("page")
        let refresh = Task { await h.list.load() }
        await h.fake.waitForArrival("page")
        let flagging = Task { await h.list.toggleFlag(row) }
        try await waitUntil { (try? h.row(3).summary.isFlagged) == true }
        await h.fake.release("page")
        await refresh.value
        await flagging.value
        #expect(try h.row(3).summary.isFlagged)
    }

    @Test func swipingRightTogglesReadOnTheServer() async throws {
        let h = await Self.harness()
        h.actions.perform(.toggleRead, on: try h.row(3), in: h.list)
        try await waitUntil { (try? h.row(3).summary.isSeen) == true }
        #expect(await h.fake.calls.contains("setFlag seen true [3]"))
    }

    @Test func aFullSwipeMovesTheMailToTrashWithoutAsking() async throws {
        let h = await Self.harness()
        await h.actions.trash(try h.row(3), in: h.list)
        #expect(h.actions.deletingForever == nil)
        #expect(!h.list.rows.contains { $0.uid == 3 })
        #expect(await h.fake.folders[Self.trash]?.map(\.summary.subject) == ["舊信", "公告 3"])
        #expect(await h.fake.folders["INBOX"]?.contains { $0.summary.uid == 3 } == false)
        #expect(h.list.status.actionError == nil)
    }

    @Test func aFullSwipeInsideTrashAsksBeforeDeletingForever() async throws {
        let h = await Self.harness()
        await h.list.select(.real(Self.trash))
        await h.actions.trash(try h.row(1), in: h.list)
        let model = try #require(h.actions.deletingForever)
        #expect(!(await h.fake.calls).contains { $0.hasPrefix("setFlag") || $0.hasPrefix("copy") })
        #expect(h.list.rows.contains { $0.uid == 1 })

        h.actions.deletingForever = nil
        await h.actions.deleteForever(model, in: h.list)
        #expect(h.list.rows.isEmpty)
        #expect(await h.fake.folders[Self.trash]?.isEmpty == true)
    }

    @Test func withNoTrashFolderTheSwipeAsksBeforeDeletingForever() async throws {
        let h = await Self.harness(withTrash: false)
        await h.actions.trash(try h.row(3), in: h.list)
        #expect(h.actions.deletingForever?.route.uid == 3)
        #expect(await h.fake.calls.contains("createFolder \(Self.trash)"))
        #expect(!(await h.fake.calls).contains { $0.hasPrefix("copy") })
        #expect(await h.fake.folders["INBOX"]?.count == 3)
    }

    @Test func aSecondSwipeWhileTheFirstIsInFlightIsIgnored() async throws {
        let h = await Self.harness()
        let row = try h.row(3)
        await h.fake.hold("copy")
        let first = Task { await h.actions.trash(row, in: h.list) }
        await h.fake.waitForArrival("copy")
        await h.actions.trash(row, in: h.list)
        await h.fake.release("copy")
        await first.value
        #expect((await h.fake.calls).filter { $0.hasPrefix("copy ") }.count == 1)
        #expect(await h.fake.folders[Self.trash]?.count == 2)
    }

    @Test func movingFilesTheMailInTheChosenFolder() async throws {
        let h = await Self.harness()
        h.actions.perform(.move, on: try h.row(2), in: h.list)
        let model = try #require(h.actions.moving)
        await h.actions.move(model, to: Self.course, in: h.list)
        #expect(!h.list.rows.contains { $0.uid == 2 })
        #expect(await h.fake.folders[Self.course]?.map(\.summary.subject) == ["公告 2"])
    }

    @Test func aFailedMoveKeepsTheRowAndShowsWhy() async throws {
        let h = await Self.harness()
        await h.fake.update { $0.copyError = .unreachable }
        await h.actions.move(h.actions.message(try h.row(2), in: h.list), to: Self.course, in: h.list)
        #expect(h.list.rows.contains { $0.uid == 2 })
        #expect(h.list.status.actionError == MailAccountManager.LoginError(MailClientError.unreachable).message)
    }

    @Test func aMoveThatFailsAfterTheSignInEndsShowsNoError() async throws {
        let h = await Self.harness()
        let model = h.actions.message(try h.row(2), in: h.list)
        await h.fake.update { $0.copyError = .unreachable }
        await h.fake.holdNext("copy")
        let moving = Task { await h.actions.move(model, to: Self.course, in: h.list) }
        await h.fake.waitForArrival("copy")
        h.account.endSignIn()
        await h.fake.release("copy")
        await moving.value
        #expect(h.list.status.actionError == nil)
    }

    @Test func aReplyFromTheListQuotesTheMailTheMessageScreenWouldLoad() async throws {
        let h = await Self.harness()
        let context = try #require(await h.actions.compose(.reply, row: try h.row(3), in: h.list))
        #expect(context.mode == .reply)
        #expect(context.message?.folder == "INBOX")
        #expect(context.message?.uid == 3)
        #expect(context.original?.subject == "公告 3")
        #expect(context.original?.bodyText.contains("body") == true)
        #expect(h.actions.composing == nil)
    }

    @Test func aReplyWhoseMailCannotLoadOpensNothingAndShowsWhy() async throws {
        let h = await Self.harness()
        await h.fake.update { $0.detailError = .unreachable }
        #expect(await h.actions.compose(.forward, row: try h.row(3), in: h.list) == nil)
        #expect(h.list.status.actionError == MailAccountManager.LoginError(MailClientError.unreachable).message)
    }

    @Test func theMoreSwipeOpensTheSheetForItsRow() async throws {
        let h = await Self.harness()
        h.actions.perform(.more, on: try h.row(1), in: h.list)
        #expect(h.actions.sheetRow?.uid == 1)
    }
}
#endif
