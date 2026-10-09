#if os(macOS)
import Foundation

extension AppFeature {
    /// Features not surfaced in the macOS UI.
    ///
    /// Library sits behind an opt-in toggle on iOS and depends on flows not designed for Mac
    /// (Discussion Room booking, Lecture sign-up) that would be dead taps in the sidebar.
    /// `LibraryService` still compiles so a Mac port can flip the switch without code changes.
    ///
    /// School Mail is iOS and iPadOS only: its code is `#if os(iOS)`, SwiftMail is not
    /// linked on macOS, and `isImplemented` is false there too.
    static let macHiddenFeatures: Set<AppFeature> = libraryRelatedFeatures.union([.schoolMail])

    /// True iff this feature should be visible anywhere in the macOS UI
    /// (sidebar, More page, future Settings tab pickers).
    var isAvailableOnMac: Bool {
        !Self.macHiddenFeatures.contains(self)
    }

    /// Default sidebar pin order on macOS, used the first time the app
    /// runs on Mac (before the user has customised `configuredTabs`).
    /// Wider than the iOS default tab bar because Mac sidebars don't
    /// have iPhone's 4-tab cap — surface the most-used features
    /// up-front so the user doesn't have to dig into Settings → Sidebar
    /// to find them.
    static let macDefaultTabs: [AppFeature] = [
        .home, .classTable, .calendar, .gpa, .announcements,
    ]
}
#endif
