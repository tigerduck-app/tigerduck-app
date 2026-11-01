import Foundation
import UIKit
import WebKit

/// Find in page. The page script collects the text and marks the matches, in a script world of
/// the app's own that the page cannot reach. Matching runs here off the main actor, where a slow
/// regular expression can be stopped; run in the page, it would hold the page's thread until done.
@MainActor
@Observable
final class BrowserFind {
    enum Mode: String, CaseIterable { case plain, regex }

    private(set) var isActive = false
    var query = ""
    var mode = Mode.plain
    private(set) var count = 0
    private(set) var index = 0
    @ObservationIgnored var run: (_ arguments: [String: Any]) async -> Any? = { _ in nil }
    @ObservationIgnored private var searches = 0

    var position: String {
        if count > 0 { return "\(index + 1)/\(count)" }
        return query.isEmpty ? "" : String(localized: "browser_find_none")
    }

    func start() {
        query = ""
        count = 0
        index = 0
        isActive = true
    }

    /// The query and count stay for the find bar as it slides away; the next start clears them.
    func end() {
        isActive = false
        searches += 1
        Task { _ = await run(["action": "clear"]) }
    }

    /// Marks every match of the query in the page and shows the first; a later search wins.
    func search() async {
        searches += 1
        let search = searches
        var marked = 0
        if !query.isEmpty {
            let texts = await run(["action": "texts"]) as? [String] ?? []
            guard search == searches else { return }
            let query = query, regex = mode == .regex
            let found = await Task.detached(priority: .userInitiated) {
                Self.ranges(of: query, regex: regex, in: texts)
            }.value
            guard search == searches else { return }
            if !found.isEmpty { marked = await run(["action": "mark", "ranges": found]) as? Int ?? 0 }
        } else {
            _ = await run(["action": "clear"])
        }
        guard search == searches else { return }
        count = marked
        index = 0
        if count > 0 { _ = await run(["action": "select", "index": 0]) }
    }

    func next() async { await move(by: 1) }

    func previous() async { await move(by: -1) }

    private func move(by step: Int) async {
        guard count > 0 else { return }
        index = (index + step + count) % count
        _ = await run(["action": "select", "index": index])
    }

    /// Safari stops at a thousand matches too; more would only slow the page.
    nonisolated static let limit = 1000

    /// Each match of `query` in `texts` as `[text, start, end]`, in the UTF-16 offsets the DOM
    /// counts, ignoring case. Plain text matches any run of white space where the query has one,
    /// at its ends too, as a page's source line breaks show as a single space. None for a query of
    /// only white space or an expression that does not compile, and none once the search has run
    /// past `budget`, as a pattern such as `(a+)+$` backtracks exponentially.
    nonisolated static func ranges(
        of query: String, regex: Bool, in texts: [String], budget: Duration = .milliseconds(500)
    ) -> [[Int]] {
        if !regex, query.allSatisfy(\.isWhitespace) { return [] }
        let pattern = regex ? query : query.split(separator: /\s+/, omittingEmptySubsequences: false)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "\\s+")
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let deadline = ContinuousClock.now + budget
        var found: [[Int]] = []
        for (text, string) in texts.enumerated() where found.count < limit {
            var expired = ContinuousClock.now > deadline
            if !expired {
                // Progress reports come during a long match too, so a slow one stops here.
                expression.enumerateMatches(in: string, options: .reportProgress,
                                            range: NSRange(location: 0, length: string.utf16.count)) { match, _, stop in
                    if ContinuousClock.now > deadline {
                        expired = true
                        stop.pointee = true
                    } else if let range = match?.range, range.length > 0 {
                        found.append([text, range.location, NSMaxRange(range)])
                        if found.count == limit { stop.pointee = true }
                    }
                }
            }
            if expired { return [] }
        }
        return found
    }
}
