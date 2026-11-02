import Foundation

/// The hosts the app reaches on its own and signs in to, and those the browser gives the stored
/// password to or signs in to through a site's sign-in link, whose pages are held to the pins that
/// guard the app's own requests. The browser judges every other host by system trust (ADR 0025).
enum BrowserPinnedHosts {
    static let hosts: Set<String> = SchoolWeb.serviceHosts
        .union(
            [AppConstants.moodleBaseURL, PortalLanguage.zh.pageURL, MailConstants.webmailURL]
                .compactMap(BrowserRouting.host(of:))
        )
        .union(BrowserRouting.ssoHosts)
        .union(BrowserSchoolSites.passwordHosts)
        .union(BrowserSchoolSites.signInLinkHosts)
}
