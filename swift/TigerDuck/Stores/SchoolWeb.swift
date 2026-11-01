import Foundation

@MainActor
enum SchoolWeb {
    nonisolated static func isMoodlePage(_ url: URL) -> Bool {
        MoodleAutologinService.isMoodlePage(url)
    }

    /// `url` through a one-time Moodle autologin link when a key is due, else `url` itself.
    static func signedIn(_ url: URL) async -> URL {
        await MoodleAutologinService.shared.url(for: url)
    }

    static var schoolCookies: HTTPCookieStorage { NTUSTSessionManager.shared.ntustCookieJar }
}
