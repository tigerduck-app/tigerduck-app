import SwiftUI

/// Feature pages per release, keyed by marketing version
/// (`CFBundleShortVersionString`) and shown before that release's
/// `whatsnew.json` summary. A user who skipped versions sees every skipped
/// release's pages, oldest first, then only the installed version's summary.
/// A release with no pages has no key. Copy is inline Traditional Chinese and
/// English (``WhatsNewText``), not `app-translation`. Longer pages, and any
/// with a custom demo, get their own file (`WhatsNewSchoolMailPages.swift`).
/// The pages are iPhone and iPad only; the Mac, with no What's New, gets none.
enum WhatsNewCatalog {
    static let releases: [String: [WhatsNewPage]] = {
        #if os(iOS)
        return [
            // Mail shipped in 2.2.0, but few noticed it then; every
            // upgrade lands on 2.3.0, so it's introduced here.
            "2.3.0": [.schoolMail, .mailInBottomBar],
        ]
        #else
        return [:]
        #endif
    }()
}
