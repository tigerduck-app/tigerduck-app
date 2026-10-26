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

    /// The body `run` calls with `action` and its arguments: texts gives the text of every run it
    /// searches, mark wraps the ranges found in them and gives how many matches it marked. A run
    /// is the text nodes of one stretch of inline text, so a phrase split by `<b>` still matches;
    /// a block, a line break or skipped content that shows ends it. Editable text, such as a
    /// rich-text answer, and SVG are skipped.
    nonisolated static let script = """
    var marker = 'data-tigerduck-find';
    var marks = function() { return document.querySelectorAll('mark[' + marker + ']'); };
    function clear() {
      window.tigerduckFindRuns = [];
      marks().forEach(function(mark) {
        var parent = mark.parentNode;
        while (mark.firstChild) parent.insertBefore(mark.firstChild, mark);
        parent.removeChild(mark);
        parent.normalize();
      });
      return 0;
    }
    function blockOf(element) {
      while (element !== document.body && /^(inline|contents)$/.test(getComputedStyle(element).display)) {
        element = element.parentElement;
      }
      return element;
    }
    function texts() {
      clear();
      if (!document.body) return [];
      var runs = [], run = null, block = null;
      var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
        acceptNode: function(node) {
          if (node.nodeType === Node.ELEMENT_NODE) {
            var skipped = node.isContentEditable || node.matches('script, style, noscript, textarea, select, template, svg');
            var display = getComputedStyle(node).display;
            // The walk never stops at an element, so one that shows between two texts ends the run here.
            if (display !== 'none' && (skipped || node.localName === 'br' || !/^(inline|contents)$/.test(display))) run = null;
            return skipped ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_SKIP;
          }
          var parent = node.parentElement;
          if (!parent || parent.getClientRects().length === 0) return NodeFilter.FILTER_REJECT;
          return NodeFilter.FILTER_ACCEPT;
        }
      });
      while (walker.nextNode()) {
        var node = walker.currentNode;
        var nodeBlock = blockOf(node.parentElement);
        if (!run || nodeBlock !== block) {
          run = { nodes: [], starts: [], text: '' };
          runs.push(run);
          block = nodeBlock;
        }
        run.nodes.push(node);
        run.starts.push(run.text.length);
        run.text += node.nodeValue;
      }
      runs = runs.filter(function(run) { return run.text.trim(); });
      window.tigerduckFindRuns = runs;
      return runs.map(function(run) { return run.text; });
    }
    function mark() {
      var runs = window.tigerduckFindRuns || [];
      var pieces = [], count = 0;
      ranges.forEach(function(found) {
        var run = runs[found[0]];
        if (!run) return;
        var before = pieces.length;
        run.nodes.forEach(function(node, i) {
          var length = (i + 1 < run.nodes.length ? run.starts[i + 1] : run.text.length) - run.starts[i];
          var start = Math.max(found[1] - run.starts[i], 0), end = Math.min(found[2] - run.starts[i], length);
          if (start < end && node.isConnected && node.nodeValue.length === length) pieces.push([node, start, end, count]);
        });
        if (pieces.length > before) count++;
      });
      // From the last piece back, so wrapping one leaves the offsets before it in place.
      for (var i = pieces.length - 1; i >= 0; i--) {
        var range = document.createRange();
        range.setStart(pieces[i][0], pieces[i][1]);
        range.setEnd(pieces[i][0], pieces[i][2]);
        var mark = document.createElement('mark');
        mark.setAttribute(marker, pieces[i][3]);
        mark.style.cssText = 'color: #000; background: #FFE8A3; border-radius: 3px; padding: 0; box-shadow: none';
        range.surroundContents(mark);
      }
      return count;
    }
    function select() {
      var shown = null;
      marks().forEach(function(mark) {
        var on = Number(mark.getAttribute(marker)) === index;
        mark.style.background = on ? '#FFB340' : '#FFE8A3';
        if (on && !shown) shown = mark;
      });
      if (shown) shown.scrollIntoView({ block: 'center', inline: 'nearest' });
      return shown !== null;
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
