#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct MailSwipeScreenTests {
    private static var language: String { Bundle.main.preferredLocalizations.first ?? "en" }
    private static let longSubject = "115 學年度第 1 學期加退選公告：請於期限前完成線上選課並確認所有課程衝堂與學分上限 Course Add/Drop"

    private static func messages() -> [FakeMailClient.Message] {
        var flagged = FakeMailClient.message(uid: 3, name: "學生事務處 Office of Student Affairs", subject: longSubject, seen: true)
        flagged.summary.flagged = true
        flagged.summary.hasAttachments = true
        return [
            FakeMailClient.message(uid: 1, name: "王小明", subject: "Re: 期末專題分組", seen: true),
            flagged,
            FakeMailClient.message(uid: 4, name: "圖書館", subject: "借閱到期提醒：您有 3 本書將於 3 天內到期"),
            FakeMailClient.message(uid: 5, name: "教務處註冊組", subject: "加退選公告"),
        ]
    }

    private static func list() async -> (MailListViewModel, MailRowActions) {
        let fake = FakeMailClient(folders: ["INBOX": messages(), MailFolderRole.trash.imapName: []])
        let account = AccountSession()
        let session = MailPageSession(idleClose: .milliseconds(10), open: { fake }, account: account)
        let list = MailListViewModel(session: session, account: account, cache: SchoolMailTestDoubles.temporaryCache(),
                                     noteSeenByPage: { _, _ in }, signOutEvents: NotificationCenter(),
                                     warmDelay: { try? await Task.sleep(for: .seconds(86_400)) },
                                     catchUpDelay: { try? await Task.sleep(for: .seconds(86_400)) })
        await list.load()
        await list.background.waitForFlagStorage()
        return (list, MailRowActions(prefs: InMemoryMailPreferences(), notifier: MailNotifier(center: RecordingNotificationCenter())))
    }

    @Test("the list draws a flag on a flagged row where the folder keeps flags, beside the clip, inside the width",
          arguments: ClubScreensTests.looks)
    func list(look: ClubScreensTests.Look) async throws {
        try await withAccessibilityAutomation {
            let (list, actions) = await Self.list()
            try #require(list.canFlag("INBOX"))
            let page = List {
                MailListRowsSection(viewModel: list, actions: actions, accentColor: .blue,
                                    policy: VisualStylePolicy(preset: .default), onOpen: { _ in })
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.backgroundPrimary)
            let window = try ClubScreensTests.show(page, look: look, height: look.textSize == .large ? 812 : 2400)
            defer { window.isHidden = true }
            let flagged = String(localized: "school_mail_flagged")
            try await waitUntil { ClubScreensTests.shows("期末專題分組", in: window) }
            try await Task.sleep(for: .milliseconds(400))
            window.saveSnapshot(as: "mail-swipe-list-\(look.testDescription)-\(Self.language)")

            let texts = exposedAccessibilityTexts(in: window)
            #expect(Set(texts.filter { $0.contains(flagged) }).count == 1, "\(texts)")
            for label in exposedAccessibilityLabels(in: window) {
                let element = try #require(accessibilityElement(labeled: label, in: window))
                #expect(element.accessibilityFrame.maxX <= window.bounds.maxX + 0.5, "\(label)")
            }
        }
    }

    @Test("the More sheet offers the three replies, read, flag and move, then delete, as drawn",
          arguments: ClubScreensTests.looks)
    func moreSheet(look: ClubScreensTests.Look) async throws {
        try await withAccessibilityAutomation {
            var summary = FakeMailClient.message(uid: 9, name: "電子計算機中心", subject: "您的信箱容量已使用 98%", seen: true).summary
            summary.flagged = false
            let row = MailListRow(folder: "INBOX", summary: summary)
            let sheet = MailRowActionsSheet(row: row, canFlag: true, composing: nil, onAction: { _ in })
            let window = try ClubScreensTests.show(sheet, look: look, height: look.textSize == .large ? 640 : 1800)
            defer { window.isHidden = true }
            let titles = [
                MailRowAction.compose(.reply), .compose(.replyAll), .compose(.forward), .toggleRead, .toggleFlag, .move, .trash,
            ].map { $0.title(for: summary) }
            try await waitUntil { accessibilityElement(labeled: titles[6], in: window) != nil }
            try await Task.sleep(for: .milliseconds(400))
            window.saveSnapshot(as: "mail-swipe-more-\(look.testDescription)-\(Self.language)")

            let shown = exposedAccessibilityLabels(in: window)
            var seen = Set<String>()
            #expect(shown.filter { titles.contains($0) && seen.insert($0).inserted } == titles, "\(shown)")
            #expect(titles[3] == String(localized: "school_mail_mark_unread"))
            #expect(titles[4] == String(localized: "school_mail_flag"))
            #expect(shown.contains("電子計算機中心"))
            #expect(shown.contains(String(localized: "action_close")))
            for title in titles {
                let element = try #require(accessibilityElement(labeled: title, in: window), "\(title)")
                #expect(element.accessibilityTraits.contains(.button), "\(title)")
                #expect(element.accessibilityFrame.maxX <= window.bounds.maxX + 0.5, "\(title)")
            }
        }
    }

    @Test("the More sheet leaves out Flag where the folder does not keep it")
    func moreSheetWithoutFlag() async throws {
        try await withAccessibilityAutomation {
            let summary = FakeMailClient.message(uid: 9, name: "電子計算機中心", seen: true).summary
            let sheet = MailRowActionsSheet(row: MailListRow(folder: "INBOX", summary: summary), canFlag: false,
                                            composing: nil, onAction: { _ in })
            let window = try ClubScreensTests.show(sheet, look: ClubScreensTests.looks[0], height: 640)
            defer { window.isHidden = true }
            let delete = String(localized: "school_mail_delete")
            try await waitUntil { accessibilityElement(labeled: delete, in: window) != nil }
            #expect(accessibilityElement(labeled: String(localized: "school_mail_flag"), in: window) == nil)
            #expect(accessibilityElement(labeled: String(localized: "school_mail_move_to"), in: window) != nil)
        }
    }
}
#endif
