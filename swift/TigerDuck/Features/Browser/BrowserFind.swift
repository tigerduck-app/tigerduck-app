import Foundation
import WebKit

/// Find in page. `WKWebView.find` has no regular expressions, so both modes run a script that
/// marks the matching text, in a script world of the app's own that the page cannot reach.
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
        let found = query.isEmpty
            ? await run(["action": "clear"])
            : await run(["action": "find", "query": query, "regex": mode == .regex])
        guard search == searches else { return }
        count = max((found as? Int) ?? 0, 0)
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

    /// The ranges of `query` in `text` as `[start, end]` pairs in UTF-16 offsets, null for a
    /// regular expression that does not compile. Plain text runs as an escaped expression, so both
    /// modes ignore case the same way.
    nonisolated static let matcher = """
    function tigerduckFindRanges(text, query, regex) {
      if (!query) return [];
      var source = regex ? query : query.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&');
      var expression;
      try { expression = new RegExp(source, 'gi'); } catch (error) { return null; }
      var found = [];
      var match;
      while ((match = expression.exec(text)) !== null) {
        if (match[0].length === 0) { expression.lastIndex += 1; continue; }
        found.push([match.index, match.index + match[0].length]);
      }
      return found;
    }
    """

    /// Safari stops at a thousand matches too; more would only slow the page.
    nonisolated static let limit = 1000

    /// The body `run` calls with `action` and its arguments: find gives the count, -1 for an
    /// expression that does not compile. A match across two elements is not found.
    nonisolated static let script = matcher + """

    var marker = 'data-tigerduck-find';
    var marks = function() { return document.querySelectorAll('mark[' + marker + ']'); };
    function clear() {
      marks().forEach(function(mark) {
        var parent = mark.parentNode;
        while (mark.firstChild) parent.insertBefore(mark.firstChild, mark);
        parent.removeChild(mark);
        parent.normalize();
      });
      return 0;
    }
    function textNodes() {
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
      return nodes;
    }
    function find() {
      clear();
      if (!document.body) return 0;
      var count = 0;
      var nodes = textNodes();
      for (var n = 0; n < nodes.length && count < \(limit); n++) {
        var found = tigerduckFindRanges(nodes[n].nodeValue, query, regex);
        if (found === null) return -1;
        found = found.slice(0, \(limit) - count);
        for (var i = found.length - 1; i >= 0; i--) {
          var range = document.createRange();
          range.setStart(nodes[n], found[i][0]);
          range.setEnd(nodes[n], found[i][1]);
          var mark = document.createElement('mark');
          mark.setAttribute(marker, '');
          mark.style.cssText = 'color: #000; background: #FFE8A3; border-radius: 3px; padding: 0; box-shadow: none';
          range.surroundContents(mark);
        }
        count += found.length;
      }
      return count;
    }
    function select() {
      var all = marks();
      all.forEach(function(mark, i) { mark.style.background = i === index ? '#FFB340' : '#FFE8A3'; });
      if (all[index]) all[index].scrollIntoView({ block: 'center', inline: 'nearest' });
      return all.length;
    }
    if (action === 'find') return find();
    if (action === 'select') return select();
    return clear();
    """
}

extension WKWebView {
    /// One call of ``BrowserFind/script``, with every argument the script reads present.
    func runFind(_ arguments: [String: Any]) async -> Any? {
        let all: [String: Any] = ["action": "clear", "query": "", "regex": false, "index": 0]
            .merging(arguments) { $1 }
        return try? await callAsyncJavaScript(BrowserFind.script, arguments: all, in: nil, contentWorld: .defaultClient)
    }
}
