#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

struct MailRecipientSuggestionsTests {
    static let me = "me@mail.example.edu.tw"
    static let now = Date(timeIntervalSince1970: 1_793_000_000)
    static let drafts = MailFolderRole.drafts.imapName

    static func mail(
        from: String, name: String? = nil, to: [String] = [], cc: [String] = [], daysAgo: Double = 0,
        uid: UInt32 = 1, deleted: Bool = false
    ) -> MailSummary {
        MailSummary(uid: uid, fromName: name, fromAddress: from, to: to, cc: cc, subject: "x",
                    date: now.addingTimeInterval(-daysAgo * 86_400), isSeen: true, isAnswered: false, isDeleted: deleted,
                    size: 1, hasAttachments: false, isExternal: false)
    }

    static func page(_ summaries: [MailSummary], in folder: String = "INBOX") -> MailFolderPage {
        MailFolderPage(folder: folder, uidValidity: 1, messageCount: summaries.count, summaries: summaries, oldestLoadedSequence: nil)
    }

    static func contacts(_ pages: [MailFolderPage]) -> [MailRecipientSuggestions.Contact] {
        MailRecipientSuggestions.contacts(in: pages, own: me, roles: [.drafts: drafts], now: now)
    }

    static func contact(_ name: String?, _ address: String, score: Double = 1) -> MailRecipientSuggestions.Contact {
        MailRecipientSuggestions.Contact(address: MailAddress(name: name, address: address), score: score)
    }

    @Test func someoneTheStudentWroteToCountsTwiceAsMuchAsSomeoneWhoWrote() {
        let ranked = Self.contacts([
            Self.page([Self.mail(from: "ta@mail.example.edu.tw", name: "陳助教")]),
            Self.page([Self.mail(from: Self.me, to: ["\"陳志明老師\" <cmchen@mail.example.edu.tw>"])], in: "Sent"),
        ])
        #expect(ranked.map(\.address.address) == ["cmchen@mail.example.edu.tw", "ta@mail.example.edu.tw"])
        #expect(ranked.map(\.score) == [2, 1])
        #expect(ranked.map(\.address.name) == ["陳志明老師", "陳助教"])
    }

    @Test func aMailCountsHalfAsMuchEveryThirtyDays() throws {
        let ranked = Self.contacts([Self.page([
            Self.mail(from: "old@mail.example.edu.tw", daysAgo: 30, uid: 1),
            Self.mail(from: "older@mail.example.edu.tw", daysAgo: 60, uid: 2),
            Self.mail(from: "new@mail.example.edu.tw", uid: 3),
        ])])
        #expect(ranked.map(\.address.address) == ["new@mail.example.edu.tw", "old@mail.example.edu.tw", "older@mail.example.edu.tw"])
        let scores = ranked.map(\.score)
        #expect(abs(scores[1] - 0.5) < 1e-9 && abs(scores[2] - 0.25) < 1e-9, "\(scores)")
    }

    @Test func manyOldMailOutrankOneNew() {
        let old = (1...3).map { Self.mail(from: "often@mail.example.edu.tw", daysAgo: 30, uid: $0) }
        let ranked = Self.contacts([Self.page(old + [Self.mail(from: "once@mail.example.edu.tw", uid: 9)])])
        #expect(ranked.first?.address.address == "often@mail.example.edu.tw")
    }

    @Test func theStudentDraftsDeletedMailAndNoReplySendersAreLeftOut() {
        let ranked = Self.contacts([
            Self.page([
                Self.mail(from: "noreply@moodle.example.edu.tw", uid: 1),
                Self.mail(from: "do-not-reply@example.edu.tw", uid: 2),
                Self.mail(from: "gone@mail.example.edu.tw", uid: 3, deleted: true),
                Self.mail(from: "ME@mail.example.edu.tw", to: ["me@mail.example.edu.tw", "kept@mail.example.edu.tw"], uid: 4),
            ]),
            Self.page([Self.mail(from: Self.me, to: ["draft@mail.example.edu.tw"])], in: Self.drafts),
        ])
        #expect(ranked.map(\.address.address) == ["kept@mail.example.edu.tw"])
    }

    @Test func junkTrashAndDraftsAreLeftOutByTheirRoleWhateverTheirName() {
        let junk = Self.page([Self.mail(from: "spam@mail.example.edu.tw")], in: MailFolderRole.junk.imapName)
        let trash = Self.page([Self.mail(from: "binned@mail.example.edu.tw")], in: MailFolderRole.trash.imapName)
        let drafts = Self.page([Self.mail(from: Self.me, to: ["draft@mail.example.edu.tw"])], in: "Drafts")
        let kept = Self.page([Self.mail(from: "kept@mail.example.edu.tw")])
        let ranked = MailRecipientSuggestions.contacts(in: [junk, trash, drafts, kept], own: Self.me, roles: [.drafts: "Drafts"], now: Self.now)
        #expect(ranked.map(\.address.address) == ["kept@mail.example.edu.tw"])

        let mailboxDrafts = Self.page([Self.mail(from: Self.me, to: ["draft@mail.example.edu.tw"])], in: Self.drafts)
        #expect(MailRecipientSuggestions.contacts(in: [junk, trash, mailboxDrafts], own: Self.me, roles: [:], now: Self.now).isEmpty)
    }

    @Test func anAddressTheComposerCannotSendIsNotSuggested() {
        let ranked = Self.contacts([Self.page([
            Self.mail(from: "陳@mail.example.edu.tw", uid: 1),
            Self.mail(from: Self.me, to: ["小陳 <陳@mail.example.edu.tw>", "kept@mail.example.edu.tw"], uid: 2),
        ])])
        #expect(ranked.map(\.address.address) == ["kept@mail.example.edu.tw"])
    }

    @Test func onePersonWhateverTheCaseNamedAsTheLatestMailNamesThem() {
        let ranked = Self.contacts([Self.page([
            Self.mail(from: "YiChun@mail.example.edu.tw", name: "陳怡君", daysAgo: 1, uid: 1),
            Self.mail(from: "yichun@mail.example.edu.tw", name: "Yi-Chun Chen", daysAgo: 5, uid: 2),
            Self.mail(from: "yichun@mail.example.edu.tw", daysAgo: 0, uid: 3),
        ])])
        #expect(ranked.count == 1)
        #expect(ranked.first?.address == MailAddress(name: "陳怡君", address: "yichun@mail.example.edu.tw"))
    }

    @Test func aChineseNameMatchesAnyPartOfIt() {
        let contacts = [Self.contact("陳怡君", "yichun@mail.example.edu.tw"), Self.contact("林小美", "lin@mail.example.edu.tw")]
        #expect(MailRecipientSuggestions.matching(contacts, typed: "怡君", taken: []).map(\.address) == ["yichun@mail.example.edu.tw"])
        #expect(MailRecipientSuggestions.matching(contacts, typed: "陳", taken: []).map(\.address) == ["yichun@mail.example.edu.tw"])
    }

    @Test func theAddressMatchesAndCaseDoesNotMatter() {
        let contacts = [Self.contact("Bo-Han Chen", "phchen@mail.example.edu.tw"), Self.contact(nil, "Lin@mail.example.edu.tw")]
        #expect(MailRecipientSuggestions.matching(contacts, typed: "PHCHEN", taken: []).map(\.address) == ["phchen@mail.example.edu.tw"])
        #expect(MailRecipientSuggestions.matching(contacts, typed: "bo-HAN", taken: []).map(\.address) == ["phchen@mail.example.edu.tw"])
        #expect(MailRecipientSuggestions.matching(contacts, typed: "ｐｈｃｈｅｎ", taken: []).map(\.address) == ["phchen@mail.example.edu.tw"])
        #expect(MailRecipientSuggestions.matching(contacts, typed: " lin@", taken: []).map(\.address) == ["Lin@mail.example.edu.tw"])
        #expect(MailRecipientSuggestions.matching(contacts, typed: "nobody", taken: []).isEmpty)
        #expect(MailRecipientSuggestions.matching(contacts, typed: " ", taken: []).isEmpty)
    }

    @Test func aNameOrAddressThatStartsWithTheTextComesFirstThenTheRank() {
        let contacts = [
            Self.contact(nil, "achen@mail.example.edu.tw", score: 9),
            Self.contact("Mei Chen", "mei@mail.example.edu.tw", score: 5),
            Self.contact(nil, "chen.lab@mail.example.edu.tw", score: 3),
        ]
        #expect(MailRecipientSuggestions.matching(contacts, typed: "chen", taken: []).map(\.address)
                == ["mei@mail.example.edu.tw", "chen.lab@mail.example.edu.tw", "achen@mail.example.edu.tw"])
    }

    @Test func atMostFiveAreSuggestedNoneAlreadyAddressed() {
        let contacts = (1...7).map { Self.contact("陳 \($0)", "chen\($0)@mail.example.edu.tw", score: Double(10 - $0)) }
        let five = MailRecipientSuggestions.matching(contacts, typed: "陳", taken: [])
        #expect(five.map(\.address) == (1...5).map { "chen\($0)@mail.example.edu.tw" })
        let rest = MailRecipientSuggestions.matching(contacts, typed: "陳", taken: ["chen1@mail.example.edu.tw", "chen3@mail.example.edu.tw"])
        #expect(rest.map(\.address) == [2, 4, 5, 6, 7].map { "chen\($0)@mail.example.edu.tw" })
    }
}
#endif
