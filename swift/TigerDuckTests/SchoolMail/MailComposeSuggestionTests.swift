#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

extension MailComposeViewModelTests {
    typealias Fixture = MailRecipientSuggestionsTests

    static func suggestionCache() -> MailCache {
        let cache = SchoolMailTestDoubles.temporaryCache()
        cache.savePage(Fixture.page([
            Fixture.mail(from: Fixture.me, to: ["陳怡君 <yichun@mail.example.edu.tw>"], uid: 1),
            Fixture.mail(from: Fixture.me, to: ["陳柏翰 <phchen@mail.example.edu.tw>"], daysAgo: 3, uid: 2),
        ], in: Self.sent))
        cache.savePage(Fixture.page([
            Fixture.mail(from: "cmchen@mail.example.edu.tw", name: "陳志明老師", uid: 1),
            Fixture.mail(from: "cs-ta@mail.example.edu.tw", name: "資工系 陳助教", daysAgo: 2, uid: 2),
            Fixture.mail(from: "lin@mail.example.edu.tw", name: "林小美", uid: 3),
        ]))
        return cache
    }

    static func suggestingModel(account: AccountSession = AccountSession(), cache: MailCache) -> MailComposeViewModel {
        MailComposeViewModel(
            context: MailComposeContext(mode: .new),
            session: MailPageSession(idleClose: .milliseconds(10), open: { RefusingMailClient() }, account: account),
            sender: MailAddress(name: nil, address: Fixture.me),
            folderRoles: [.inbox: "INBOX", .sent: Self.sent, .drafts: Self.drafts],
            prefs: InMemoryMailPreferences(),
            cache: cache,
            sleep: { _ in },
            now: { Fixture.now }
        )
    }

    static let suggested = ["yichun", "phchen", "cmchen", "cs-ta"].map { "\($0)@mail.example.edu.tw" }

    @Test func theRecipientFieldsSuggestThePeopleInTheCachedMailButNotOnesAlreadyAddressed() async {
        let model = Self.suggestingModel(cache: Self.suggestionCache())
        await model.prepare()
        #expect(model.recipientSuggestions(for: "陳").map(\.address) == Self.suggested)
        #expect(model.recipientSuggestions(for: "林").map(\.name) == ["林小美"])

        model.cc = "陳怡君 <YiChun@mail.example.edu.tw>, 陳"
        #expect(model.recipientSuggestions(for: "陳").map(\.address) == Array(Self.suggested.dropFirst()))
    }

    @Test func aSignOutTakesTheSuggestionsAwayAndTheNextScreenFindsNone() async {
        let account = AccountSession()
        let cache = Self.suggestionCache()
        let model = Self.suggestingModel(account: account, cache: cache)
        await model.prepare()
        #expect(!model.recipientSuggestions(for: "陳").isEmpty)

        account.endSignIn()
        cache.clearAll()
        #expect(model.recipientSuggestions(for: "陳").isEmpty)
        let next = Self.suggestingModel(account: account, cache: cache)
        await next.prepare()
        #expect(next.recipientSuggestions(for: "陳").isEmpty)
    }
}

@MainActor
@Suite(.serialized)
struct MailComposeSuggestionScreenTests {
    static let language = Bundle.main.preferredLocalizations.first ?? "en"

    /// A list keeps the cells of rows it no longer shows, hidden, for reuse.
    static func rows(in window: UIWindow) -> [NSObject] {
        let shown: [UIView] = window.descendants(ofType: UICollectionView.self).first?.visibleCells ?? [window]
        var seen = Set<String>()
        return shown.flatMap { exposedAccessibilityElements(in: $0) }.filter {
            let label = $0.accessibilityLabel ?? ""
            return label.contains("@mail.example.edu.tw") && !label.contains("<") && seen.insert(label).inserted
        }
    }

    @Test("typing in To lists the matches under it, each read name then address, and a pick becomes its bubble",
          arguments: ClubScreensTests.looks)
    func suggestAndPick(look: ClubScreensTests.Look) async throws {
        try await withAccessibilityAutomation {
            let model = MailComposeViewModelTests.suggestingModel(cache: MailComposeViewModelTests.suggestionCache())
            let window = try ClubScreensTests.show(MailComposeView(viewModel: model), look: look,
                                                   height: look.textSize == .large ? 812 : 1600)
            defer { window.isHidden = true }
            try await waitUntil { !window.descendants(ofType: UITextField.self).isEmpty }
            let field = try #require(window.descendants(ofType: UITextField.self).first)
            field.becomeFirstResponder()
            try await waitUntil { field.isFirstResponder }
            field.insertText("陳")

            let names = ["陳怡君", "陳柏翰", "陳志明老師", "資工系 陳助教"]
            try await waitUntil { Self.rows(in: window).count == names.count }
            let rows = Self.rows(in: window)
            for (row, (name, address)) in zip(rows, zip(names, MailComposeViewModelTests.suggested)) {
                let label = row.accessibilityLabel ?? ""
                #expect(label.hasPrefix(name) && label.hasSuffix(address), "\(label)")
            }
            #expect(accessibilityElement(labeled: String(localized: "a11y_school_mail_recipient_suggestions"), in: window) != nil)
            try await Task.sleep(for: .milliseconds(400))
            window.saveSnapshot(as: "mail-suggest-\(look.testDescription)-\(Self.language)")

            _ = rows.first?.accessibilityActivate()
            try await waitUntil { model.to == "陳怡君 <yichun@mail.example.edu.tw>" }
            try await waitUntil { Self.rows(in: window).isEmpty }
            #expect(accessibilityElement(labeled: "陳怡君 <yichun@mail.example.edu.tw> ×", in: window) != nil)
            #expect(window.descendants(ofType: UITextField.self).first?.isFirstResponder == true)
            try await Task.sleep(for: .milliseconds(400))
            window.saveSnapshot(as: "mail-picked-\(look.testDescription)-\(Self.language)")
        }
    }
}
#endif
