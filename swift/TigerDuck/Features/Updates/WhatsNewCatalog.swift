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
///         title: WhatsNewText(en: "Copy a course code", zhHant: "複製課程代碼"),
///         body: WhatsNewText(en: "Tap a course code to copy it.", zhHant: "點一下課程代碼即可複製。")
///     ),
/// ],
/// ```
///
/// Copy is written inline in Traditional Chinese and English
/// (``WhatsNewText``), the same two languages as the summary — not
/// through `app-translation`. Longer pages, and any with a custom demo,
/// get their own file (see `WhatsNewResetBottomBarPage.swift`).
///
/// The pages are iPhone/iPad-only, so the Mac — which shows no What's
/// New — gets an empty catalog.
enum WhatsNewCatalog {
    static let releases: [String: [WhatsNewPage]] = {
        #if os(iOS)
        return [
            "2.3.0": [.resetBottomBar],
        ]
        #else
        return [:]
        #endif
    }()
}
