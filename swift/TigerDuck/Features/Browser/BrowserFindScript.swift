import UIKit
import WebKit

enum BrowserFindScript {
    nonisolated static let source = """
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
      var pieces = (window.tigerduckFindMatches || [])[window.tigerduckFindCurrent] || [];
      return pieces.filter(function(range) { return !range.collapsed; });
    }
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
    if (!window.tigerduckFindListens) {
      window.tigerduckFindListens = true;
      addEventListener('scroll', spotlight, true);
      addEventListener('resize', spotlight);
    }
    function centre(range) {
      var scale = view[2] / innerWidth;
      var top = (view[0] + view[3]) / scale - scrollY, bottom = (view[1] + view[3]) / scale - scrollY;
      for (var box = range.startContainer.parentElement; box; box = box.parentElement) {
        if (box === document.scrollingElement) continue;
        var style = getComputedStyle(box), m = range.getBoundingClientRect(), b = box.getBoundingClientRect();
        if (box.scrollHeight > box.clientHeight && /auto|scroll/.test(style.overflowY)) {
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
    func runFind(_ arguments: [String: Any]) async -> Any? {
        let inset = scrollView.adjustedContentInset
        let view = [inset.top, bounds.height - inset.bottom, bounds.width, scrollView.contentOffset.y]
        let all: [String: Any] = ["action": "clear", "ranges": [[Int]](), "index": 0, "view": view]
            .merging(arguments) { $1 }
        let result = try? await callAsyncJavaScript(BrowserFindScript.source, arguments: all, in: nil, contentWorld: .defaultClient)
        if let match = result as? [Double], match.count == 5, match[4] > 0 { reveal(match) }
        return result
    }

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
