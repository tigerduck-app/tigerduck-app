import WebKit

/// What the browser adds to pages: Moodle's logout hidden and blocked, each site's zoom, and a
/// dark page where the site has none.
enum BrowserPageScripts {
    private nonisolated static let logoutTargets = ["/login/logout.php", "/auth/oidc/logout.php"]
        .flatMap { ["https://\(BrowserRouting.moodleHost)\($0)", $0] }
    private nonisolated static let logoutLinks = logoutTargets.map { "a[href^=\"\($0)\"]" }
    private nonisolated static let logoutForms = logoutTargets.map { "form[action^=\"\($0)\"]" }

    /// Every link and form to the logout, and what they leave standing alone: the user menu's
    /// divider, the footer's "logged in as" line and the sign-in page's button wrapper.
    nonisolated static let logoutSelector = (logoutLinks + logoutForms).joined(separator: ", ")
    nonisolated static let leftOverSelector = (
        logoutLinks.map { ".dropdown-divider:has(+ \($0))" }
            + logoutLinks.map { ".logininfo:has(\($0))" }
            + logoutForms.map { ".singlebutton:has(> \($0))" }
    ).joined(separator: ", ")

    /// A stylesheet, so the user menu Moodle draws later is matched too; `:has()` sits in a rule of
    /// its own, as a browser without it drops the whole rule.
    nonisolated static let hideLogout = """
    (function() {
      if (location.hostname !== '\(BrowserRouting.moodleHost)') return;
      var style = document.createElement('style');
      style.textContent = '\(logoutSelector) { display: none !important; }\\n\(leftOverSelector) { display: none !important; }';
      (document.head || document.documentElement).appendChild(style);
    })();
    """

    /// Each site's zoom in `zooms`, by lowercased host, as Safari's page zoom: the body grows and
    /// its text wraps again. On iOS `WKWebView.pageZoom` only magnifies the page, which then
    /// scrolls sideways. Run again on a page, it applies a changed zoom.
    nonisolated static func zoom(_ zooms: [String: Int]) -> String {
        let table = (try? JSONSerialization.data(withJSONObject: zooms)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        (function() {
          var zoom = (\(table))[location.hostname.toLowerCase()];
          var style = document.querySelector('style[data-tigerduck-zoom]');
          if (!style) {
            style = document.createElement('style');
            style.setAttribute('data-tigerduck-zoom', '');
            (document.head || document.documentElement).appendChild(style);
          }
          style.textContent = zoom ? 'body { zoom: ' + zoom / 100 + ' !important; }' : '';
        })();
        """
    }

    /// Under a dark appearance, Dark Reader recolors a page that draws itself light, as most school
    /// pages have no dark style; its styles are for the screen only, so a print keeps the site's
    /// colors. Checked again once the page's styles load and when the appearance changes; a page
    /// with its own dark style is kept. Dark Reader is vendored in
    /// `swift/TigerDuck/Features/Browser/DarkReader/`; without it in the bundle this is nil.
    nonisolated static let darken: String? = Bundle.main.url(forResource: "darkreader", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        .map { $0 + "\n" + darkenWithDarkReader }

    private nonisolated static let darkenWithDarkReader = """
    (function() {
      var dark = matchMedia('(prefers-color-scheme: dark)');
      // Find's marks and spotlight keep the colors it gives them.
      var fixes = { ignoreInlineStyle: ['[data-tigerduck-find]', '[data-tigerduck-find-light]'] };
      // Lets a cross-origin stylesheet be recolored where its server allows CORS.
      DarkReader.setFetchMethod(window.fetch);
      // The page's own colors, read with Dark Reader's styles switched off for the moment.
      function drawsLight() {
        var ours = Array.prototype.map.call(document.querySelectorAll('style.darkreader'), function(style) { return style.sheet; })
          .filter(function(sheet) { return sheet && !sheet.disabled; });
        ours.forEach(function(sheet) { sheet.disabled = true; });
        try {
          var root = document.documentElement;
          var color = [document.body, root].filter(Boolean)
            .map(function(element) { return getComputedStyle(element).backgroundColor; })
            .filter(function(color) { return !/^transparent$|, 0\\)$/.test(color); })[0];
          var meta = document.querySelector('meta[name="color-scheme"]');
          if (!color) return !/dark/.test(getComputedStyle(root).colorScheme + (meta ? meta.content : ''));
          var rgb = color.match(/[\\d.]+/g).map(Number);
          return 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2] > 127.5;
        } finally {
          ours.forEach(function(sheet) { sheet.disabled = false; });
        }
      }
      function update() {
        var wanted = dark.matches && drawsLight();
        if (wanted === DarkReader.isEnabled()) return;
        if (wanted) DarkReader.enable({}, fixes);
        else DarkReader.disable();
      }
      update();
      dark.addEventListener('change', update);
      document.addEventListener('DOMContentLoaded', update);
      addEventListener('load', update);
    })();
    """

    /// Blocks the logout for every resource type, frames and scripts' requests included, which
    /// the navigation delegate never sees. Content blocker patterns have no alternation, so one rule each.
    nonisolated static let logoutRules: String = {
        let host = BrowserRouting.moodleHost.replacingOccurrences(of: ".", with: "\\\\.")
        let rules = ["login/+logout\\\\.php", "auth/+oidc/+logout\\\\.php"].map { path in
            #"{"trigger":{"url-filter":"^https?://\#(host)\\.?(:[0-9]+)?/+\#(path)"},"action":{"type":"block"}}"#
        }
        return "[" + rules.joined(separator: ",") + "]"
    }()

    private static var compiledRules: WKContentRuleList?

    static let rulesDeadline: Duration = .seconds(2)

    /// The page loads without the rule list when WebKit's store does not answer in time; the
    /// navigation delegate still refuses the logout, and a later browser gets the list.
    static func install(in controller: WKUserContentController) async {
        addScripts(to: controller)
        guard let rules = await answer(within: rulesDeadline, compileLogoutRules) else {
            return AppLogger.breadcrumb("browser opened without its logout rule list", category: "browser")
        }
        controller.add(rules)
    }

    /// Again after a zoom changes, for the pages loaded next: a user script cannot be replaced alone.
    static func addScripts(to controller: WKUserContentController) {
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: hideLogout, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        controller.addUserScript(WKUserScript(source: zoom(BrowserSites.stored.zoom), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        guard let darken else {
            return AppLogger.breadcrumb("browser opened without Dark Reader", category: "browser")
        }
        // The app's own world: page scripts can neither call it nor see the `window.chrome` it defines.
        controller.addUserScript(WKUserScript(source: darken, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
    }

    private static func compileLogoutRules() async -> WKContentRuleList? {
        if let compiledRules { return compiledRules }
        do {
            compiledRules = try await WKContentRuleListStore.default()
                .compileContentRuleList(forIdentifier: "TigerDuckBrowserLogout", encodedContentRuleList: logoutRules)
        } catch {
            AppLogger.captureError(error, context: ["flow": "browserLogoutRules"])
        }
        return compiledRules
    }

    /// What `work` gives within `deadline`, or nil; `work` runs on to its end in a task of its own.
    static func answer<T>(within deadline: Duration, _ work: @escaping () async -> T?) async -> T? {
        let (answers, continuation) = AsyncStream<T?>.makeStream()
        Task { continuation.yield(await work()) }
        let timer = Task {
            do { try await Task.sleep(for: deadline) } catch { return }
            continuation.yield(nil)
        }
        defer {
            timer.cancel()
            continuation.finish()
        }
        for await answer in answers { return answer }
        return nil
    }
}
