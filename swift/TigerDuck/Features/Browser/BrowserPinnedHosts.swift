import Foundation

/// The hosts the app reaches on its own and signs in to, whose pins the browser checks too: a
/// page from one of them is held to the pins that guard the app's own requests, and the pins win.
/// The browser judges every other host by the system's trust store alone (ADR 0025).
enum BrowserPinnedHosts {
    static let hosts: Set<String> = SchoolWeb.serviceHosts
        .union(
            [AppConstants.moodleBaseURL, PortalLanguage.zh.pageURL, MailConstants.webmailURL]
                .compactMap(BrowserRouting.host(of:))
        )
        .union(BrowserRouting.ssoHosts)
}
