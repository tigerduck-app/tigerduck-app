import SwiftUI

struct NowNextView: View {
    @EnvironmentObject private var store: ScheduleStore

    private var policy: WatchVisualStylePolicy {
        WatchVisualStylePolicy(preset: store.snapshot?.visualPreset ?? .default)
    }

    var body: some View {
        // `NextClassResolver.resolve(now:)` reads `AppClock.now()`, but
        // SwiftUI has no way to know the clock advanced unless a state
        // change pokes the view. Without this periodic rebuild, the
        // watch would freeze on the resolution computed at snapshot
        // arrival even as real (or ticking-fake) time moves past the
        // next boundary. Snapshot-driven override flips already kick a
        // rebuild via `@EnvironmentObject`, so this only needs to cover
        // the no-snapshot-change case. 60 s matches class-boundary
        // granularity and keeps watch power use trivial.
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            ScrollView {
                VStack(spacing: 12) {
                    if let snapshot = store.snapshot, !snapshot.courses.isEmpty {
                        let result = NextClassResolver.resolve(courses: snapshot.courses, now: AppClock.now())
                        if let current = result.current {
                            ClassCard(title: String(localized: "watch_now"), course: current, policy: policy)
                        }
                        if let next = result.next {
                            ClassCard(title: String(localized: "watch_next"), course: next, policy: policy)
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
                            String(localized: "watch_empty_not_signed_in"),
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
            .navigationTitle(String(localized: "watch_now_next_title"))
        }
    }
}

private struct ClassCard: View {
    let title: String
    let course: WatchCourse
    let policy: WatchVisualStylePolicy

    var body: some View {
        let courseColor = Color(hex: course.colorHex) ?? .accentColor
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                // Same rationale as TodayRow: the accent stripe is only
                // needed when the surface itself is neutral.
                if !policy.usesTintedCardSurface {
                    Rectangle()
                        .fill(courseColor)
                        .frame(width: 3)
                }
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
        .padding(8)
        .background(
            policy.cardBackground(for: courseColor),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}
