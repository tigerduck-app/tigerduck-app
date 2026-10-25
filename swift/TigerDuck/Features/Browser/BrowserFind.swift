import Foundation
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
    /// Runs a call of ``script`` in the page; set by the web view.
    @ObservationIgnored var run: (_ arguments: [String: Any]) async -> Any? = { _ in nil }
    @ObservationIgnored private var searches = 0

    /// What the field shows after the query: the match on screen and how many, or that none matched.
    var position: String {
        if count > 0 { return "\(index + 1)/\(count)" }
        return query.isEmpty ? "" : String(localized: "browser_find_none")
    }

    func start() { isActive = true }

    func end() {
        isActive = false
        query = ""
        count = 0
        index = 0
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
    /// counts, ignoring case. None for an expression that does not compile, and none once the
    /// search has run past `budget`, as a pattern such as `(a+)+$` backtracks exponentially.
    nonisolated static func ranges(
        of query: String, regex: Bool, in texts: [String], budget: Duration = .milliseconds(500)
    ) -> [[Int]] {
        let options: NSRegularExpression.Options = regex ? .caseInsensitive : [.caseInsensitive, .ignoreMetacharacters]
        guard let expression = try? NSRegularExpression(pattern: query, options: options) else { return [] }
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

    /// The body `run` calls with `action` and its arguments: texts gives the text of every node
    /// it searches, mark wraps the ranges found in them and gives how many it marked.
    nonisolated static let script = """
    var marker = 'data-tigerduck-find';
    var marks = function() { return document.querySelectorAll('mark[' + marker + ']'); };
    function clear() {
      window.tigerduckFindNodes = [];
      marks().forEach(function(mark) {
        var parent = mark.parentNode;
        while (mark.firstChild) parent.insertBefore(mark.firstChild, mark);
        parent.removeChild(mark);
        parent.normalize();
      });
      return 0;
    }
    function texts() {
      clear();
      if (!document.body) return [];
      var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
        acceptNode: function(node) {
          var parent = node.parentElement;
          if (!parent || parent.closest('script, style, noscript, textarea, select, template')) return NodeFilter.FILTER_REJECT;
          if (!node.nodeValue.trim() || parent.getClientRects().length === 0) return NodeFilter.FILTER_REJECT;
          return NodeFilter.FILTER_ACCEPT;
        }
      });
      var nodes = [];
      while (walker.nextNode()) nodes.push(walker.currentNode);
      window.tigerduckFindNodes = nodes;
      return nodes.map(function(node) { return node.nodeValue; });
    }
    function mark() {
      var nodes = window.tigerduckFindNodes || [];
      var count = 0;
      // From the last range back, so wrapping one leaves the offsets before it in place.
      for (var i = ranges.length - 1; i >= 0; i--) {
        var node = nodes[ranges[i][0]];
        if (!node || !node.isConnected || ranges[i][2] > node.nodeValue.length) continue;
        var range = document.createRange();
        range.setStart(node, ranges[i][1]);
        range.setEnd(node, ranges[i][2]);
        var mark = document.createElement('mark');
        mark.setAttribute(marker, '');
        mark.style.cssText = 'color: #000; background: #FFE8A3; border-radius: 3px; padding: 0; box-shadow: none';
        range.surroundContents(mark);
        count++;
      }
      return count;
    }
    function select() {
      var all = marks();
      all.forEach(function(mark, i) { mark.style.background = i === index ? '#FFB340' : '#FFE8A3'; });
      if (all[index]) all[index].scrollIntoView({ block: 'center', inline: 'nearest' });
      return all.length;
    }
    if (action === 'texts') return texts();
    if (action === 'mark') return mark();
    if (action === 'select') return select();
    return clear();
    """
}

extension WKWebView {
    /// One call of ``BrowserFind/script``, with every argument the script reads present.
    func runFind(_ arguments: [String: Any]) async -> Any? {
        let all: [String: Any] = ["action": "clear", "ranges": [[Int]](), "index": 0]
            .merging(arguments) { $1 }
        return try? await callAsyncJavaScript(BrowserFind.script, arguments: all, in: nil, contentWorld: .defaultClient)
    }
}
