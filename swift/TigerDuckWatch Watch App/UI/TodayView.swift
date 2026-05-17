import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var store: ScheduleStore

    private var todaysCourses: [WatchCourse] {
        guard let snapshot = store.snapshot else { return [] }
        let cal = Calendar(identifier: .iso8601)
        let raw = cal.component(.weekday, from: AppClock.now())
        let iso = ((raw + 5) % 7) + 1
        return snapshot.courses
            .filter { $0.weekday == iso }
            .sorted { $0.startHHmm < $1.startHHmm }
    }

    private var policy: WatchVisualStylePolicy {
        WatchVisualStylePolicy(preset: store.snapshot?.visualPreset ?? .default)
    }

    var body: some View {
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

private struct TodayRow: View {
    let course: WatchCourse
    let policy: WatchVisualStylePolicy

    var body: some View {
        let courseColor = Color(hex: course.colorHex) ?? .accentColor
        HStack(spacing: 8) {
            // The accent stripe only earns its place in the Apple preset,
            // where the rest of the card is intentionally neutral. The
            // TigerDuck preset already carries the course identity via
            // the tinted surface, so we drop the stripe to avoid a
            // double-strong colour treatment.
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
