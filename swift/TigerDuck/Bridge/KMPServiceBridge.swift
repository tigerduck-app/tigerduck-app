import Foundation

/// Bridge layer for calling KMP shared module methods.
/// Currently returns mock data; will be replaced by actual KMP framework calls in Phase 3.
enum KMPServiceBridge {
    static func fetchCourses() async -> [SDCourse] {
        MockData.courses
    }

    static func fetchAssignments() async -> [SDAssignment] {
        MockData.assignments
    }

    static func fetchAnnouncements() async -> [SDAnnouncement] {
        MockData.announcements
    }

    static func fetchCalendarEvents() async -> [SDCalendarEvent] {
        MockData.calendarEvents
    }
}
