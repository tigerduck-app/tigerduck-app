#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

struct BrowserFindMatcherTests {
    private func ranges(_ text: String, _ query: String, regex: Bool = false) -> [[Int]] {
        BrowserFind.ranges(of: query, regex: regex, in: [text])
    }

    /// Fast to the first text, exponential in the second: done, the search would find the x.
    static let slowTexts = ["x", String(repeating: "a", count: 40) + "!"]
    static let slowPattern = "x|(a+)+$"

    @Test func plainTextIgnoresCase() {
        #expect(ranges("Moodle and moodle", "MOODLE") == [[0, 0, 6], [0, 11, 17]])
    }

    @Test func plainTextMatchesExpressionCharactersAsThemselves() {
        #expect(ranges("a.b axb", "a.b") == [[0, 0, 3]])
        #expect(ranges("(1+1) [x] \\d", "(1+1)") == [[0, 0, 5]])
        #expect(ranges("cost $5 ^", "$5 ^") == [[0, 5, 9]])
        #expect(ranges("a\\b", "\\") == [[0, 1, 2]])
    }

    @Test func aRegularExpressionMatchesItsPattern() {
        #expect(ranges("第一週：介紹，第三週：提案", "第[一二三四]週", regex: true) == [[0, 0, 3], [0, 7, 10]])
        #expect(ranges("HW1 hw22", "hw\\d+", regex: true) == [[0, 0, 3], [0, 4, 8]])
    }

    @Test func anExpressionThatDoesNotCompileFindsNothing() {
        #expect(ranges("text (", "(", regex: true).isEmpty)
        #expect(ranges("text (", "(", regex: false) == [[0, 5, 6]])
    }

    @Test func emptyMatchesAreSkipped() {
        #expect(ranges("baaa", "a*", regex: true) == [[0, 1, 4]])
    }

    @Test func offsetsCountUTF16UnitsAsTheDOMDoes() {
        #expect(ranges("😀作業😀作業", "作業") == [[0, 2, 4], [0, 6, 8]])
    }

    @Test func eachRangeNamesItsText() {
        #expect(BrowserFind.ranges(of: "a", regex: false, in: ["no", "a A"]) == [[1, 0, 1], [1, 2, 3]])
    }

    @Test func matchesStopAtTheLimit() {
        let texts = Array(repeating: "a a", count: BrowserFind.limit)
        #expect(BrowserFind.ranges(of: "a", regex: false, in: texts).count == BrowserFind.limit)
    }

    @Test(.timeLimit(.minutes(1)))
    func aSlowExpressionGivesUpWithinItsBudget() {
        let started = ContinuousClock.now
        let found = BrowserFind.ranges(of: Self.slowPattern, regex: true, in: Self.slowTexts, budget: .milliseconds(200))
        #expect(found.isEmpty)
        #expect(ContinuousClock.now - started < .seconds(1))
    }
}

@MainActor
struct BrowserFindTests {
    private final class Page {
        var calls: [[String: Any]] = []
        var texts = ["作業一", "作業二", "作業三"]
        var actions: [String?] { calls.map { $0["action"] as? String } }
    }

    private func find(_ page: Page) -> BrowserFind {
        let find = BrowserFind()
        find.run = { arguments in
            page.calls.append(arguments)
            switch arguments["action"] as? String {
            case "texts": return page.texts
            case "mark": return (arguments["ranges"] as? [[Int]])?.count ?? 0
            default: return 0
            }
        }
        return find
    }

    @Test func aSearchMarksTheMatchesAndShowsTheFirst() async {
        let page = Page()
        let find = find(page)
        find.query = "作業."
        find.mode = .regex
        await find.search()

        #expect(find.count == 3 && find.index == 0)
        #expect(find.position == "1/3")
        #expect(page.actions == ["texts", "mark", "select"])
        #expect(page.calls[1]["ranges"] as? [[Int]] == [[0, 0, 3], [1, 0, 3], [2, 0, 3]])
        #expect(page.calls[2]["index"] as? Int == 0)
    }

    @Test func nextAndPreviousWrapAround() async {
        let page = Page()
        let find = find(page)
        find.query = "作業"
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
        find.mode = .regex
        await find.search()

        #expect(find.count == 0)
        #expect(find.position == String(localized: "browser_find_none"))
        #expect(page.actions == ["texts"])
        await find.next()
        #expect(page.calls.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func aSlowExpressionSaysNoMatches() async {
        let page = Page()
        page.texts = BrowserFindMatcherTests.slowTexts
        let find = find(page)
        find.query = BrowserFindMatcherTests.slowPattern
        find.mode = .regex
        await find.search()

        #expect(find.count == 0)
        #expect(find.position == String(localized: "browser_find_none"))
        #expect(page.actions == ["texts"])
    }

    @Test func anEmptyQueryClearsTheMarksAndShowsNothing() async {
        let page = Page()
        let find = find(page)
        await find.search()

        #expect(page.actions == ["clear"])
        #expect(find.position.isEmpty)
    }

    @Test func endingClearsTheQueryAndTheMarks() async {
        let page = Page()
        let find = find(page)
        find.start()
        find.query = "作業"
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
