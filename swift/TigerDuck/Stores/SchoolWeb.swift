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

    /// The school hosts the services in School/ reach on their own.
    static let serviceHosts: Set<String> = {
        let reached: [URL?] = [
            MoodleTokenHarvest.ssoBaseURL,
            URL(string: LibraryRequests.baseURL),
            ClassroomUsageService.queryURL,
            CourseLookupService.courseSearchAPI,
            CourseSelectionService.courseSelectionRoot,
            NTUSTScoreService.scoreRootURL,
            SemesterCatalog.semestersAPI,
        ]
        return Set(reached.compactMap { $0?.host(percentEncoded: false)?.lowercased() })
    }()
}
