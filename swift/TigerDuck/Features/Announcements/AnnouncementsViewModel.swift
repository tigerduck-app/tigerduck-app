import SwiftUI

@Observable
final class AnnouncementsViewModel {
    var announcements: [SDAnnouncement] = []
    var selectedDepartments: Set<String> = []
    var searchText: String = ""

    var departments: [String] {
        Array(Set(announcements.map(\.department))).sorted()
    }

    var filteredAnnouncements: [SDAnnouncement] {
        var result = announcements
        if !selectedDepartments.isEmpty {
            result = result.filter { selectedDepartments.contains($0.department) }
        }
        if !searchText.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.summary.localizedCaseInsensitiveContains(searchText)
            }
        }
        return result.sorted { $0.publishDate > $1.publishDate }
    }

    func toggleDepartment(_ dept: String, appState: AppState) {
        if selectedDepartments.contains(dept) {
            selectedDepartments.remove(dept)
        } else {
            selectedDepartments.insert(dept)
        }
        if appState.rememberAnnouncementFilter {
            appState.savedAnnouncementDepartments = selectedDepartments
        }
    }

    func load(appState: AppState) {
        announcements = MockData.announcements
        // Restore saved filter if enabled
        if appState.rememberAnnouncementFilter {
            selectedDepartments = appState.savedAnnouncementDepartments
        }
    }
}
