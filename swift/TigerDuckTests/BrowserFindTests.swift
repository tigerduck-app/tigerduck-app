#if os(iOS)
import Foundation
import JavaScriptCore
import Testing
@testable import TigerDuck

struct BrowserFindMatcherTests {
    /// `nil` when the matcher answers null, for an expression that does not compile.
    private func ranges(_ text: String, _ query: String, regex: Bool = false) -> [[Int]]? {
        let context = JSContext()!
        context.evaluateScript(BrowserFind.matcher)
        let answer = context.objectForKeyedSubscript("tigerduckFindRanges").call(withArguments: [text, query, regex])!
        if answer.isNull { return nil }
        return (answer.toArray() as? [[NSNumber]])?.map { $0.map(\.intValue) }
    }

    @Test func plainTextIgnoresCase() {
        #expect(ranges("Moodle and moodle", "MOODLE") == [[0, 6], [11, 17]])
    }

    @Test func plainTextMatchesExpressionCharactersAsThemselves() {
        #expect(ranges("a.b axb", "a.b") == [[0, 3]])
        #expect(ranges("(1+1) [x] \\d", "(1+1)") == [[0, 5]])
        #expect(ranges("cost $5 ^", "$5 ^") == [[5, 9]])
        #expect(ranges("a\\b", "\\") == [[1, 2]])
    }

    @Test func aRegularExpressionMatchesItsPattern() {
        #expect(ranges("第一週：介紹，第三週：提案", "第[一二三四]週", regex: true) == [[0, 3], [7, 10]])
        #expect(ranges("HW1 hw22", "hw\\d+", regex: true) == [[0, 3], [4, 8]])
    }

    @Test func anExpressionThatDoesNotCompileIsNull() {
        #expect(ranges("text", "(", regex: true) == nil)
        #expect(ranges("text", "(", regex: false) == [])
    }

    @Test func emptyMatchesAreSkippedRatherThanLoopingForever() {
        #expect(ranges("baaa", "a*", regex: true) == [[1, 4]])
        #expect(ranges("abc", "", regex: true) == [])
    }

    @Test func offsetsCountUTF16UnitsAsTheDOMDoes() {
        #expect(ranges("😀作業😀作業", "作業") == [[2, 4], [6, 8]])
    }
}

@MainActor
struct BrowserFindTests {
    private final class Page {
        var calls: [[String: Any]] = []
        var found: Any? = 3
    }

    private func find(_ page: Page) -> BrowserFind {
        let find = BrowserFind()
        find.run = { arguments in
            page.calls.append(arguments)
            return arguments["action"] as? String == "find" ? page.found : 0
        }
        return find
    }

    @Test func aSearchCountsTheMatchesAndShowsTheFirst() async {
        let page = Page()
        let find = find(page)
        find.query = "作業"
        find.mode = .regex
        await find.search()

        #expect(find.count == 3 && find.index == 0)
        #expect(find.position == "1/3")
        #expect(page.calls.first?["query"] as? String == "作業")
        #expect(page.calls.first?["regex"] as? Bool == true)
        #expect(page.calls.last?["action"] as? String == "select")
        #expect(page.calls.last?["index"] as? Int == 0)
    }

    @Test func nextAndPreviousWrapAround() async {
        let page = Page()
        let find = find(page)
        find.query = "a"
        await find.search()

        await find.previous()
        #expect(find.index == 2)
        await find.next()
        await find.next()
        #expect(find.index == 1)
        #expect(page.calls.last?["index"] as? Int == 1)
    }

    @Test func noMatchOrABrokenExpressionSaysNoMatches() async {
        let page = Page()
        let find = find(page)
        find.query = "("
        page.found = -1
        await find.search()

        #expect(find.count == 0)
        #expect(find.position == String(localized: "browser_find_none"))
        await find.next()
        #expect(page.calls.count == 1)
    }

    @Test func anEmptyQueryClearsTheMarksAndShowsNothing() async {
        let page = Page()
        let find = find(page)
        await find.search()

        #expect(page.calls.map { $0["action"] as? String } == ["clear"])
        #expect(find.position.isEmpty)
    }

    @Test func endingClearsTheQueryAndTheMarks() async {
        let page = Page()
        let find = find(page)
        find.start()
        find.query = "a"
        await find.search()

        find.end()
        while page.calls.last?["action"] as? String != "clear" { await Task.yield() }
        #expect(!find.isActive && find.query.isEmpty && find.count == 0)
    }

    @Test func findAndPrintNeedALoadedPageWithNoErrorOrSignIn() {
        let page = URL(string: "https://moodle2.ntust.edu.tw/my/")!
        #expect(BrowserPage.canUsePage(failure: nil, signIn: .idle, url: page))
        #expect(!BrowserPage.canUsePage(failure: nil, signIn: .idle, url: nil))
        #expect(!BrowserPage.canUsePage(failure: nil, signIn: .working, url: page))
        #expect(!BrowserPage.canUsePage(failure: nil, signIn: .failed, url: page))
        #expect(!BrowserPage.canUsePage(failure: .unreachable(host: "moodle2.ntust.edu.tw"), signIn: .idle, url: page))
    }
}
#endif
