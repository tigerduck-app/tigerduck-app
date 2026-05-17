#if os(macOS)
import SwiftUI

/// Landing surface on macOS: today's class slots + the next few
/// uncompleted assignments due-date sorted.
///
/// Reads directly from `DataCache` rather than going through the iOS
/// `HomeViewModel`, which has live-activity + reminder bookkeeping the
/// Mac doesn't need. `AppState.backgroundSync()` (wired to the toolbar
/// Refresh button in `MacContentView`) is what actually populates the
/// cache; this view re-derives whenever AppState's observation token
/// changes after that sync writes back.
struct MacHomeView: View {
    @Environment(AppState.self) private var appState

    /// Derived on every body re-evaluation so a `backgroundSync()` →
    /// `DataCache.save…` → `NotificationCenter.post(.dataDidUpdate)`
    /// cycle re-renders the list. Cheap because both DataCache reads
    /// are just JSON-from-disk decodes and TigerDuck never has more
    /// than a few dozen rows in either set.
    private var todaysSlots: [CourseTimeSlot] {
        let courses = currentCourses()
        let weekday = Date().scheduleWeekday
        return CourseTimeSlot.buildSlots(from: courses, weekday: weekday)
    }

    private var upcomingAssignments: [SDAssignment] {
        DataCache.shared.loadAssignments()
            .filter { !$0.isCompleted && !$0.isArchived && $0.dueDate > .now }
            .sorted { $0.dueDate < $1.dueDate }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                section(title: "Today's Classes", systemImage: "calendar.day.timeline.left") {
                    if todaysSlots.isEmpty {
                        emptyState(
                            systemImage: "cup.and.saucer",
                            title: "No classes today",
                            subtitle: "Enjoy the break."
                        )
                    } else {
                        VStack(spacing: 8) {
                            ForEach(todaysSlots) { slot in
                                classSlotRow(slot)
                            }
                        }
                    }
                }

                section(title: "Upcoming Assignments", systemImage: "list.bullet.rectangle") {
                    if upcomingAssignments.isEmpty {
                        emptyState(
                            systemImage: "checkmark.circle",
                            title: "All caught up",
                            subtitle: "No outstanding assignments."
                        )
                    } else {
                        VStack(spacing: 8) {
                            ForEach(upcomingAssignments.prefix(12), id: \.assignmentId) { assignment in
                                assignmentRow(assignment)
                            }
                        }
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func section<Body: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Body
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.title2.bold())
                .foregroundStyle(.primary)
            content()
        }
    }

    private func classSlotRow(_ slot: CourseTimeSlot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.start, style: .time)
                    .font(.body.monospacedDigit())
                Text(slot.end, style: .time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 72, alignment: .leading)

            Rectangle()
                .fill(TigerDuckTheme.courseColor(for: slot.course.courseNo))
                .frame(width: 4)
                .clipShape(Capsule())

            VStack(alignment: .leading, spacing: 2) {
                Text(slot.course.displayName)
                    .font(.headline)
                let weekday = slot.date.scheduleWeekday
                let classroom = slot.course.classroom(for: weekday)
                if !classroom.isEmpty {
                    Text(classroom)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md, style: .continuous)
                .fill(Color.secondarySystemGroupedBackgroundCompat)
        )
    }

    private func assignmentRow(_ assignment: SDAssignment) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Image(systemName: "doc.text.fill")
                .foregroundStyle(.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(assignment.displayTitle)
                    .font(.headline)
                    .lineLimit(2)
                Text(assignment.courseName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 2) {
                Text(assignment.dueDate, format: .dateTime.month().day())
                    .font(.callout.monospacedDigit())
                Text(assignment.dueDate, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md, style: .continuous)
                .fill(Color.secondarySystemGroupedBackgroundCompat)
        )
    }

    private func emptyState(systemImage: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md, style: .continuous)
                .fill(Color.secondarySystemGroupedBackgroundCompat)
        )
    }

    // MARK: - Data loading

    private func currentCourses() -> [SDCourse] {
        let semester = CourseSelectionService.currentSemesterCode()
        let semesterCourses = DataCache.shared.loadCourses(semester: semester)
        let userAdded = DataCache.shared.loadUserAddedCourses()
        return semesterCourses + userAdded
    }
}

#endif
