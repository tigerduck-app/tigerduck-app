#if os(macOS)
import SwiftUI

/// Landing surface on macOS.
///
/// Sections, top to bottom:
///   1. Greeting (+ fake-clock indicator in DEBUG)
///   2. Today's Classes: header above the Today and Next Class widget cards
///   3. Upcoming Assignments: right-click to archive, complete or undo
///
/// All sections read `DataCache`, so Refresh (`appState.backgroundSync()`) re-renders them.
struct MacHomeView: View {
    @Environment(AppState.self) private var appState
    @State private var cacheRevision: Int = 0

    var body: some View {
        // Read AppClockState.version so a debug clock override updates the greeting and
        // widgets at once, not on the next unrelated invalidation. Mirrors the iOS HomeView.
        let _ = AppClockState.shared.version
        let _ = cacheRevision
        ScrollView {
            content
                .macReadableContent(maxWidth: MacContentWidth.standard)
        }
        .onReceive(NotificationCenter.default.publisher(for: AppConstants.dataDidUpdate)) { _ in
            cacheRevision &+= 1
        }
        .alert(String(localized: "sync_conflict_title"), isPresented: Binding(
            get: { !appState.syncConflicts.isEmpty },
            set: { if !$0 { appState.resolveSyncConflicts(keepLocal: true) } }
        )) {
            Button(String(localized: "sync_conflict_use_server")) { appState.resolveSyncConflicts(keepLocal: false) }
            Button(String(localized: "sync_conflict_use_local"), role: .cancel) { appState.resolveSyncConflicts(keepLocal: true) }
        } message: {
            Text(appState.syncConflictAlertMessage)
        }
    }

    private var content: some View {
        let courses = currentCourses()
        return VStack(alignment: .leading, spacing: 28) {
            greetingRow

            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(title: String(localized: "home_section_today_courses"), systemImage: "calendar.day.timeline.left")
                MacHomeWidgetsRow(courses: courses)
            }

            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(title: String(localized: "desktop_home_section_upcoming_assignments"), systemImage: "list.bullet.rectangle")
                MacAssignmentsList(courses: courses)
            }
        }
    }

    // MARK: - Pieces

    private var greetingRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(AppClock.now().greetingText())
                .font(.largeTitle.bold())
                .foregroundStyle(.primary)
            Spacer()
            #if DEBUG
            if AppClock.currentOverride() != nil {
                Label("Fake time", systemImage: "clock.badge.exclamationmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
            }
            #endif
        }
    }

    private func sectionHeader(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.title2.bold())
            .foregroundStyle(.primary)
    }

    // MARK: - Data

    private func currentCourses() -> [SDCourse] {
        // The canonical provider applies the deletedCourseNos tombstones and customNames
        // overlay. A raw load and merge would bring a course hidden from the class table back
        // into the Home widget cards and the assignment course matcher after a refresh.
        CanonicalCourseProvider().currentCourses()
    }
}
#endif
