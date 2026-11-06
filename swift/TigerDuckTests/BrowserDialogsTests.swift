import Testing
@testable import TigerDuck

@MainActor
struct BrowserDialogsTests {
    private typealias Dialog = BrowserDialogs.Dialog

    @MainActor
    private final class Replies {
        var got: [String: [String?]] = [:]

        func reply(_ name: String) -> BrowserDialogs.Reply {
            { [self] in got[name, default: []].append($0) }
        }
    }

    private static func dialog(_ kind: Dialog.Kind, _ message: String) -> Dialog {
        Dialog(kind: kind, host: "dialog-test.ntust.edu.tw", message: message)
    }

    @Test("dialogs show one at a time in the order the page asked, and each is answered once")
    func eachIsAnsweredOnceInOrder() {
        let dialogs = BrowserDialogs(), replies = Replies()
        var shown: [Dialog] = []
        dialogs.show = { shown.append($0) }
        let first = Self.dialog(.confirm, "Submit the form?")
        let second = Self.dialog(.prompt(defaultText: "Week 1"), "Which week?")
        dialogs.ask(first, reply: replies.reply("first"))
        dialogs.ask(second, reply: replies.reply("second"))
        #expect(shown == [first])
        #expect(dialogs.shown == first)

        dialogs.answer(second, with: "Week 2")
        #expect(replies.got.isEmpty)
        dialogs.answer(first, with: "")
        dialogs.answer(first, with: nil)
        #expect(replies.got == ["first": [""]])
        #expect(shown == [first, second])

        dialogs.answer(second, with: "Week 2")
        dialogs.cancelAll()
        #expect(replies.got == ["first": [""], "second": ["Week 2"]])
        #expect(dialogs.shown == nil)
        #expect(shown == [first, second])
    }

    @Test("once a page asked a few dialogs each right after the last was answered, the rest are cancelled unseen until its next page")
    func aPageAskingOverAndOverIsCancelledUntilItsNextPage() {
        let dialogs = BrowserDialogs(), replies = Replies()
        let start = ContinuousClock.now
        dialogs.now = { start }
        var shown: [Dialog] = []
        dialogs.show = { shown.append($0) }
        let limit = BrowserDialogs.dialogsInARow
        let asked = (0...limit).map { Self.dialog(.alert, "Notice \($0)") }
        for (index, dialog) in asked.enumerated() {
            dialogs.ask(dialog, reply: replies.reply("\(index)"))
            dialogs.answer(dialog, with: "")
        }
        #expect(shown == Array(asked.prefix(limit)))
        var expected = Dictionary(uniqueKeysWithValues: (0..<limit).map { ("\($0)", [String?.some("")]) })
        expected["\(limit)"] = [nil]
        #expect(replies.got == expected)

        dialogs.pageChanged()
        let next = Self.dialog(.confirm, "Submit the form?")
        dialogs.ask(next, reply: replies.reply("next"))
        #expect(shown.last == next)
    }

    @Test("dialogs asked while another waits count as asked one right after another")
    func dialogsAskedTogetherCountAsInARow() {
        let dialogs = BrowserDialogs(), replies = Replies()
        let start = ContinuousClock.now
        dialogs.now = { start }
        var shown: [Dialog] = []
        dialogs.show = { shown.append($0) }
        let limit = BrowserDialogs.dialogsInARow
        let together = (0...limit).map { Self.dialog(.alert, "Frame \($0)") }
        for (index, dialog) in together.enumerated() { dialogs.ask(dialog, reply: replies.reply("\(index)")) }
        #expect(replies.got == ["\(limit)": [nil]])
        for dialog in together { dialogs.answer(dialog, with: "") }
        #expect(shown == Array(together.prefix(limit)))
        #expect(replies.got.count == limit + 1)
    }

    @Test("a dialog asked a while after the last answer starts the count again")
    func aPauseStartsTheCountAgain() {
        let dialogs = BrowserDialogs(), replies = Replies()
        var time = ContinuousClock.now
        dialogs.now = { time }
        var shown: [Dialog] = []
        dialogs.show = { shown.append($0) }
        let limit = BrowserDialogs.dialogsInARow
        let asked = (0..<(limit * 2)).map { Self.dialog(.confirm, "Step \($0)") }
        for (index, dialog) in asked.enumerated() {
            if index == limit { time += BrowserDialogs.inARowGap }
            dialogs.ask(dialog, reply: replies.reply("\(index)"))
            dialogs.answer(dialog, with: "")
        }
        #expect(shown == asked)
        #expect(replies.got.values.allSatisfy { $0 == [""] })
    }

    @Test("every dialog still waiting is answered as cancelled when its web view's delegate goes away, and only once")
    func goingAwayCancelsWhatWaits() async throws {
        let replies = Replies()
        var pageUI: BrowserPageUI? = BrowserPageUI { _, _ in }
        let dialogs = try #require(pageUI?.dialogs)
        dialogs.show = { _ in }
        let asked = (0..<3).map { Self.dialog(.alert, "Notice \($0)") }
        for (index, dialog) in asked.enumerated() { dialogs.ask(dialog, reply: replies.reply("\(index)")) }
        dialogs.answer(asked[0], with: "")

        withExtendedLifetime(pageUI) {}
        pageUI = nil
        try await waitUntil { dialogs.shown == nil }
        dialogs.answer(asked[1], with: "")
        dialogs.cancelAll()
        #expect(replies.got == ["0": [""], "1": [nil], "2": [nil]])
    }
}
