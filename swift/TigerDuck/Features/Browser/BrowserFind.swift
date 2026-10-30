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
    /// Runs a call of ``script`` in the page; set by the web view.
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

    /// The body `run` calls with `action` and its arguments: texts gives the text of every run it
    /// searches, mark highlights the ranges found in them and gives how many matches it marked. A
    /// run is the text nodes of one stretch of inline text, so a phrase split by `<b>` still
    /// matches; a block, a line break or skipped content that shows ends it. Editable text, such
    /// as a rich-text answer, and SVG are skipped. Highlights leave the page's text nodes whole,
    /// so the page's own scripts can still update them while find is on.
    nonisolated static let script = """
    var marker = 'data-tigerduck-find';
    var all = 'tigerduck-find', shown = 'tigerduck-find-current';
    function clear() {
      window.tigerduckFindRuns = [];
      window.tigerduckFindMatches = [];
      window.tigerduckFindCurrent = -1;
      CSS.highlights.delete(all);
      CSS.highlights.delete(shown);
      document.querySelectorAll('[' + marker + '], [' + marker + '-light]').forEach(function(element) { element.remove(); });
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
          if (!parent || getComputedStyle(parent).visibility !== 'visible') return NodeFilter.FILTER_REJECT;
          while (parent && getComputedStyle(parent).display === 'contents') parent = parent.parentElement;
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
      var matches = ranges.map(function(found) {
        var run = runs[found[0]];
        if (!run) return [];
        return run.nodes.map(function(node, i) {
          var length = (i + 1 < run.nodes.length ? run.starts[i + 1] : run.text.length) - run.starts[i];
          var start = Math.max(found[1] - run.starts[i], 0), end = Math.min(found[2] - run.starts[i], length);
          if (start >= end || !node.isConnected || node.nodeValue.length !== length) return null;
          var range = document.createRange();
          range.setStart(node, start);
          range.setEnd(node, end);
          return range;
        }).filter(Boolean);
      }).filter(function(pieces) { return pieces.length; });
      window.tigerduckFindMatches = matches;
      CSS.highlights.set(all, new Highlight(...matches.flat()));
      var style = document.createElement('style');
      style.setAttribute(marker, '');
      // Dark Reader leaves a style of this class alone, as it is the Stylus extension's, so the
      // matches keep their colors under a dark appearance.
      style.className = 'stylus';
      style.textContent = '::highlight(' + all + ') { color: #000; background-color: #FFE8A3 } '
        + '::highlight(' + shown + ') { color: #000; background-color: #FFB340 }';
      (document.head || document.documentElement).appendChild(style);
      return matches.length;
    }
    function current() {
      return (window.tigerduckFindMatches || [])[window.tigerduckFindCurrent] || [];
    }
    // A clear box over the current match whose shadow dims the rest of the page, as Safari's find does.
    function spotlight() {
      var light = document.querySelector('[' + marker + '-light]'), pieces = current();
      if (!pieces.length) return light && light.remove();
      var box = pieces.reduce(function(box, range) {
        var r = range.getBoundingClientRect();
        return [Math.min(box[0], r.left), Math.min(box[1], r.top), Math.max(box[2], r.right), Math.max(box[3], r.bottom)];
      }, [Infinity, Infinity, -Infinity, -Infinity]);
      if (!light) {
        light = document.createElement('div');
        light.setAttribute(marker + '-light', '');
        document.documentElement.appendChild(light);
      }
      light.style.cssText = 'position: absolute; z-index: 2147483647; pointer-events: none; border-radius: 3px; '
        + 'box-shadow: 0 0 0 100000px rgba(0, 0, 0, 0.35); left: ' + (box[0] + scrollX) + 'px; top: ' + (box[1] + scrollY)
        + 'px; width: ' + (box[2] - box[0]) + 'px; height: ' + (box[3] - box[1]) + 'px';
    }
    // The box scrolls with the page; a scrolled frame or a new layout moves the match under it.
    if (!window.tigerduckFindListens) {
      window.tigerduckFindListens = true;
      addEventListener('scroll', spotlight, true);
      addEventListener('resize', spotlight);
    }
    // Centres the match in each scrolled box inside the page, vertically within what the browser's
    // bars leave visible: `view` is that band's top and bottom, the view's width and its scroll
    // offset, in points. The browser scrolls the page itself.
    function centre(range) {
      var scale = view[2] / innerWidth;
      var top = (view[0] + view[3]) / scale - scrollY, bottom = (view[1] + view[3]) / scale - scrollY;
      for (var box = range.startContainer.parentElement; box; box = box.parentElement) {
        if (box === document.scrollingElement) continue;
        var style = getComputedStyle(box), m = range.getBoundingClientRect(), b = box.getBoundingClientRect();
        if (box.scrollHeight > box.clientHeight && /auto|scroll/.test(style.overflowY)) {
          // A box outside the band is centred on its own; the browser then scrolls the page to it.
          var from = Math.max(b.top, top), to = Math.min(b.bottom, bottom);
          if (from >= to) { from = b.top; to = b.bottom; }
          box.scrollTop += (m.top + m.bottom - from - to) / 2;
        }
        if (box.scrollWidth > box.clientWidth && /auto|scroll/.test(style.overflowX)) {
          box.scrollLeft += (m.left + m.right - b.left - b.right) / 2;
        }
      }
    }
    function select() {
      window.tigerduckFindCurrent = index;
      var pieces = current(), highlight = new Highlight(...pieces);
      highlight.priority = 1;
      CSS.highlights.set(shown, highlight);
      if (pieces.length) centre(pieces[0]);
      spotlight();
      if (!pieces.length) return null;
      var r = pieces[0].getBoundingClientRect();
      return [r.left + scrollX, r.top + scrollY, r.right + scrollX, r.bottom + scrollY, innerWidth];
    }
    if (action === 'texts') return texts();
    if (action === 'mark') return mark();
    if (action === 'select') return select();
    return clear();
    """
}

extension WKWebView {
    /// One call of ``BrowserFind/script``, with every argument the script reads present. A match it
    /// selects is scrolled to the middle of the band the scroll view's insets leave, which the
    /// browser sets to its bars, or to the find bar and the keyboard while it finds.
    func runFind(_ arguments: [String: Any]) async -> Any? {
        let inset = scrollView.adjustedContentInset
        let view = [inset.top, bounds.height - inset.bottom, bounds.width, scrollView.contentOffset.y]
        let all: [String: Any] = ["action": "clear", "ranges": [[Int]](), "index": 0, "view": view]
            .merging(arguments) { $1 }
        let result = try? await callAsyncJavaScript(BrowserFind.script, arguments: all, in: nil, contentWorld: .defaultClient)
        if let match = result as? [Double], match.count == 5, match[4] > 0 { reveal(match) }
        return result
    }

    /// `match` is `[left, top, right, bottom, innerWidth]` in the page's CSS pixels. Safari
    /// centres the match it shows; across, the page only moves when the match is out of view.
    private func reveal(_ match: [Double]) {
        let scale = bounds.width / match[4]
        let inset = scrollView.adjustedContentInset
        let size = scrollView.bounds.size, content = scrollView.contentSize
        var offset = scrollView.contentOffset
        let middle = (match[1] + match[3]) / 2 * scale
        offset.y = min(max(middle - (inset.top + size.height - inset.bottom) / 2, -inset.top),
                       max(content.height + inset.bottom - size.height, -inset.top))
        if match[0] * scale < offset.x + inset.left || match[2] * scale > offset.x + size.width - inset.right {
            offset.x = min(max((match[0] + match[2]) / 2 * scale - size.width / 2, -inset.left),
                           max(content.width + inset.right - size.width, -inset.left))
        }
        scrollView.setContentOffset(offset, animated: !UIAccessibility.isReduceMotionEnabled)
    }
}
