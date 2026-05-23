import Foundation

/// Where the "open in Moodle" actions should send the user on Mac. iOS
/// always uses the deep link because the iPhone Moodle app is the
/// expected handler; macOS has no first-party Moodle app, but the iPad
/// Moodle app installed via Mac App Store also registers
/// `moodlemobile://`, so the user gets to pick.
enum MoodleOpenTarget: String, CaseIterable {
    case browser
    case app
}
