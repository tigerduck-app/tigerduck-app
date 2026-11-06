import SwiftUI
import TigerDuckCore

struct NowNextView: View {
    @EnvironmentObject private var store: ScheduleStore

    private var policy: WatchVisualStylePolicy {
        WatchVisualStylePolicy(preset: store.snapshot?.visualPreset ?? .default)
    }

    var body: some View {
        TimelineView(.everyMinute) { _ in
            ScrollView {
                VStack(spacing: 12) {
                    if let snapshot = store.snapshot, !snapshot.courses.isEmpty {
                        let result = NextClassResolver.resolve(
                            courses: snapshot.courses, now: AppClock.now(), quietDays: snapshot.quietDays
                        )
                        if let current = result.current {
                            ClassCard(
                                title: store.language.string("watch_now"), course: current, span: result.currentSpan,
                                policy: policy, language: store.language
                            )
                        }
                        if let next = result.next {
                            ClassCard(
                                title: result.nextDay.headline(in: store.language), course: next, span: nil,
                                policy: policy, language: store.language
                            )
                        }
                        if result.current == nil && result.next == nil {
                            ContentUnavailableView(
                                store.language.string("watch_no_upcoming_classes"),
                                systemImage: "calendar"
                            )
                        }
                    } else if store.snapshot == nil {
                        ContentUnavailableView(
                            store.language.string("watch_open_phone_to_sync"),
                            systemImage: "iphone.gen3"
                        )
                    } else if store.snapshot?.loggedIn == false {
                        ContentUnavailableView(
                            store.language.string("watch_empty_not_signed_in"),
                            systemImage: "person.crop.circle.badge.exclamationmark"
                        )
                    } else {
                        ContentUnavailableView(
                            store.language.string("watch_no_upcoming_classes"),
                            systemImage: "calendar"
                        )
                    }
                }
                .padding(.horizontal, 8)
            }
            .navigationTitle(store.language.string("watch_now_next_title"))
        }
    }
}

struct ClassCard: View {
    let title: String
    let course: WatchCourse
    let span: ClosedRange<Date>?
    let policy: WatchVisualStylePolicy
    let language: WatchLanguage

    var caption: String { "\(title) · \(TimeRange.text(course.startHHmm, course.endHHmm))" }
    var spokenCaption: String { "\(title), \(TimeRange.spoken(course.startHHmm, course.endHHmm) { language.string($0) })" }

    var body: some View {
        HStack(spacing: 6) {
            if !policy.usesTintedCardSurface {
                Rectangle()
                    .fill(course.color)
                    .frame(width: 3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(caption)
                    .accessibilityLabel(spokenCaption)
                    .font(.footnote)
                    .foregroundStyle(course.dayChange?.start ?? course.dayChange?.end != nil ? AnyShapeStyle(Color.changeInk) : AnyShapeStyle(.secondary))
                Text(course.name)
                    .font(.headline)
                    .lineLimit(1)
                if course.dayChange?.room != nil {
                    Label(course.classroom, systemImage: "arrow.left.arrow.right")
                        .labelStyle(ChangedRoomLabelStyle())
                        .font(.callout.bold())
                        .foregroundStyle(Color.changeInk)
                } else if !course.classroom.isEmpty {
                    Text(course.classroom)
                        .font(.callout.bold())
                        .foregroundStyle(course.color)
                }
                if let span {
                    ClassCountdown(span: span, tint: course.color)
                        .padding(.top, 6)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(
            policy.cardBackground(for: course.color),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}
