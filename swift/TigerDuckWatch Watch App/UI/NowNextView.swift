import SwiftUI

struct NowNextView: View {
    @EnvironmentObject private var store: ScheduleStore

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let snapshot = store.snapshot, !snapshot.courses.isEmpty {
                    let result = NextClassResolver.resolve(courses: snapshot.courses, now: Date())
                    if let current = result.current {
                        ClassCard(title: String(localized: "watch_now"), course: current)
                    }
                    if let next = result.next {
                        ClassCard(title: String(localized: "watch_next"), course: next)
                    }
                    if result.current == nil && result.next == nil {
                        ContentUnavailableView(
                            String(localized: "watch_no_upcoming_classes"),
                            systemImage: "calendar"
                        )
                    }
                } else if store.snapshot == nil {
                    ContentUnavailableView(
                        String(localized: "watch_open_phone_to_sync"),
                        systemImage: "iphone.gen3"
                    )
                } else if store.snapshot?.loggedIn == false {
                    ContentUnavailableView(
                        String(localized: "watch_empty_not_logged_in"),
                        systemImage: "person.crop.circle.badge.exclamationmark"
                    )
                } else {
                    // Signed in but no courses on file (between terms, or
                    // class table hasn't finished fetching on the phone yet).
                    ContentUnavailableView(
                        String(localized: "watch_no_upcoming_classes"),
                        systemImage: "calendar"
                    )
                }
            }
            .padding(.horizontal, 8)
        }
        .navigationTitle("TigerDuck")
    }
}

private struct ClassCard: View {
    let title: String
    let course: WatchCourse

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Rectangle()
                    .fill(Color(hex: course.colorHex) ?? .accentColor)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(course.name)
                        .font(.headline)
                        .lineLimit(2)
                    Text("\(course.startHHmm)–\(course.endHHmm)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if !course.classroom.isEmpty {
                        Text(course.classroom)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 6)
    }
}
