import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var store: ScheduleStore

    private var todaysCourses: [WatchCourse] {
        guard let snapshot = store.snapshot else { return [] }
        return NextClassResolver.todaysClasses(
            courses: snapshot.courses, now: AppClock.now(), quietDays: snapshot.quietDays
        )
    }

    private var policy: WatchVisualStylePolicy {
        WatchVisualStylePolicy(preset: store.snapshot?.visualPreset ?? .default)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            Group {
                if todaysCourses.isEmpty {
                    ContentUnavailableView(
                        String(localized: "watch_no_upcoming_classes"),
                        systemImage: "calendar"
                    )
                } else {
                    List(todaysCourses) { course in
                        NavigationLink {
                            CourseDetailView(course: course)
                        } label: {
                            TodayRow(course: course, policy: policy)
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "watch_today"))
        }
    }
}

private struct TodayRow: View {
    let course: WatchCourse
    let policy: WatchVisualStylePolicy

    var body: some View {
        let courseColor = Color(hex: course.colorHex) ?? .accentColor
        HStack(spacing: 8) {
            if !policy.usesTintedCardSurface {
                Rectangle()
                    .fill(courseColor)
                    .frame(width: 3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(course.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(course.startHHmm)–\(course.endHHmm) · \(course.classroom)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .listRowBackground(
            policy.cardBackground(for: courseColor)
        )
    }
}
