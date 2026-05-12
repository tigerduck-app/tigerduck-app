import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var store: ScheduleStore

    private var todaysCourses: [WatchCourse] {
        guard let snapshot = store.snapshot else { return [] }
        let cal = Calendar(identifier: .iso8601)
        let raw = cal.component(.weekday, from: Date())
        let iso = ((raw + 5) % 7) + 1
        return snapshot.courses
            .filter { $0.weekday == iso }
            .sorted { $0.startHHmm < $1.startHHmm }
    }

    var body: some View {
        Group {
            if todaysCourses.isEmpty {
                ContentUnavailableView(
                    String(localized: "watch.no_classes_today"),
                    systemImage: "calendar"
                )
            } else {
                List(todaysCourses) { course in
                    NavigationLink {
                        CourseDetailView(course: course)
                    } label: {
                        TodayRow(course: course)
                    }
                }
            }
        }
        .navigationTitle(String(localized: "watch.today"))
    }
}

private struct TodayRow: View {
    let course: WatchCourse

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color(hex: course.colorHex) ?? .accentColor)
                .frame(width: 3)
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
    }
}
