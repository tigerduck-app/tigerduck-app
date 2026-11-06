import SwiftUI
import TigerDuckCore

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
        TimelineView(.everyMinute) { _ in
            Group {
                if todaysCourses.isEmpty {
                    ContentUnavailableView(
                        store.language.string("watch_no_upcoming_classes"),
                        systemImage: "calendar"
                    )
                } else {
                    List(todaysCourses) { course in
                        NavigationLink {
                            CourseDetailView(course: course, language: store.language)
                        } label: {
                            TodayRow(course: course, policy: policy, language: store.language)
                        }
                    }
                }
            }
            .navigationTitle(store.language.string("watch_today"))
        }
    }
}

private struct TodayRow: View {
    let course: WatchCourse
    let policy: WatchVisualStylePolicy
    let language: WatchLanguage

    var body: some View {
        HStack(spacing: 8) {
            if !policy.usesTintedCardSurface {
                Rectangle()
                    .fill(course.color)
                    .frame(width: 3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(course.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(TimeRange.text(course.startHHmm, course.endHHmm)) · \(course.classroom)")
                    .accessibilityLabel(
                        [TimeRange.spoken(course.startHHmm, course.endHHmm) { language.string($0) }, course.classroom]
                            .joined(separator: ", ")
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .listRowBackground(
            policy.cardBackground(for: course.color)
        )
    }
}
