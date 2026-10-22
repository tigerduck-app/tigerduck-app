import SwiftUI

enum WhatsNewCatalog {
    static let releases: [String: [WhatsNewPage]] = {
        #if os(iOS)
        return [
            "2.3.0": [.schoolMail, .mailInBottomBar],
            "2.4.0": [
                .classTableSharing, .moodleInCourseDetail, .classReminderSettings,
                .ignoreCourseAssignments, .watchComplication,
            ],
        ]
        #else
        return [:]
        #endif
    }()
}
