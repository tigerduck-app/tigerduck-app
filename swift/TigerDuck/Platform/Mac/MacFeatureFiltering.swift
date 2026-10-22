#if os(macOS)
import Foundation

extension AppFeature {
    static let macHiddenFeatures: Set<AppFeature> = libraryRelatedFeatures.union([.schoolMail, .emptyClassroom])

    var isAvailableOnMac: Bool {
        !Self.macHiddenFeatures.contains(self)
    }

    static let macDefaultTabs: [AppFeature] = [
        .home, .classTable, .calendar, .gpa, .announcements,
    ]
}
#endif
