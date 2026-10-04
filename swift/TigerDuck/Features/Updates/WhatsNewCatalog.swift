import SwiftUI

/// Feature pages per release, keyed by marketing version
/// (`CFBundleShortVersionString`, e.g. `"2.3.0"`). These come before the
/// release's summary from `whatsnew.json`; a user who skipped versions
/// sees every skipped release's pages, oldest first, then only the
/// installed version's summary.
///
/// A release with no pages simply has no key. Register a page like:
///
/// ```swift
/// "2.3.0": [
///     .feature(
///         id: "copy-course-code",
///         visual: .symbol("doc.on.doc", effect: .bounce),
///         title: "whats_new_230_copy_title",
///         body: "whats_new_230_copy_body"
///     ),
///     .optIn(
///         id: "recommended-tabs",
///         visual: .custom { RecommendedTabsDemo() },
///         title: "whats_new_230_tabs_title",
///         body: "whats_new_230_tabs_body",
///         confirm: "whats_new_230_tabs_confirm",
///         decline: "whats_new_230_tabs_decline",
///         isApplicable: { !$0.hasRecommendedTabs },
///         apply: { $0.applyRecommendedTabs() }
///     ),
/// ],
/// ```
///
/// Page text keys live in `app-translation` (`shared` group) so every
/// language picks them up.
enum WhatsNewCatalog {
    static let releases: [String: [WhatsNewPage]] = [:]
}
