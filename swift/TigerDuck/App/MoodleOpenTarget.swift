import Foundation

nonisolated enum MoodleOpenTarget: String, CaseIterable {
    case browser
    case app

    #if os(macOS)
    /// The Mac's Moodle app is the iPad one, which few install, and a `moodlemobile://` link no
    /// app takes fails with "no app handles this URL".
    static let platformDefault = MoodleOpenTarget.browser
    #else
    static let platformDefault = MoodleOpenTarget.app
    #endif
}
