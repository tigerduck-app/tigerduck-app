import WebKit

/// What the browser adds to Moodle's pages so its logout cannot be reached.
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
        controller.addUserScript(WKUserScript(source: hideLogout, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        guard let rules = await answer(within: rulesDeadline, compileLogoutRules) else {
            return AppLogger.breadcrumb("browser opened without its logout rule list", category: "browser")
        }
        controller.add(rules)
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
