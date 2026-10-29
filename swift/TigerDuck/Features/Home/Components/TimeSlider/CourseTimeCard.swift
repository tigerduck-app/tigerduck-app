import SwiftUI

struct CourseTimeCard: View {
    let state: CourseState
    let onSelect: ((CourseTimeSlot) -> Void)?
    var policy: VisualStylePolicy = VisualStylePolicy(preset: .default)

    var body: some View {
        EqualHeightHStack(alignment: .top, spacing: 8) {
            switch state {
            case .inClass(let slots):
                ForEach(slots) { slot in
                    cardContent(slot: slot, opacity: 1.0)
                        .frame(maxWidth: slots.count > 1 ? .infinity : nil)
                }
            case .between(let prev, let next):
                if let prev {
                    cardContent(slot: prev, opacity: 0.5)
                        .frame(maxWidth: .infinity)
                }
                if let next {
                    cardContent(slot: next, opacity: 0.5)
                        .frame(maxWidth: .infinity)
                }
            case .beforeFirst(let next):
                cardContent(slot: next, opacity: 0.5)
            case .afterLast(let prev):
                cardContent(slot: prev, opacity: 0.5)
            }
        }
        .animation(.smooth(duration: 0.35), value: state)
    }

    @ViewBuilder
    private func cardContent(slot: CourseTimeSlot, opacity: Double) -> some View {
        // `scrollSafeTapAction` wraps the surface in a real `Button` so the first tap
        // inside Home's ScrollView opens the detail sheet instead of being swallowed
        // (iOS 18 arbitration). `Button` supplies the `.isButton` trait and hit shape.
        cardSurface(slot: slot, opacity: opacity)
            .scrollSafeTapAction { onSelect?(slot) }
            .accessibilityHint(Text(String(localized: "a11y_course_card_open_details_hint")))
    }

    @ViewBuilder
    private func cardSurface(slot: CourseTimeSlot, opacity: Double) -> some View {
        let course = slot.course
        let isToday = AppConstants.taipeiCalendar.isDateInToday(slot.date)
        let showsChangedTime = slot.hasChangedTime && !slot.isCancelled

        HStack(alignment: .top, spacing: 10) {
            if policy.courseColorUsage == .smallAccent {
                RoundedRectangle(cornerRadius: 2)
                    .fill(course.color)
                    .frame(width: 3)
                    .padding(.vertical, 2)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    HStack(spacing: 3) {
                        if showsChangedTime {
                            Image(systemName: "clock.fill")
                                .font(.caption2)
                        }
                        Text("\(slot.start.timeString) - \(slot.end.timeString)")
                            .strikethrough(slot.isCancelled)
                    }
                        .font(.caption.bold())
                        .foregroundStyle(showsChangedTime ? Color.changeInk : timeRangeColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .layoutPriority(1)
                    Spacer(minLength: 4)
                    if !isToday {
                        Self.dateLabel(from: slot.date)
                    }
                }

                Text(course.displayName)
                    .font(.headline)
                    .strikethrough(slot.isCancelled)
                    .foregroundStyle(courseNameColor(for: course))
                    .lineLimit(1)
                subtitle(for: slot)
                    .font(.caption)
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CourseCardSurfaceModifier(tint: course.color, policy: policy))
        .opacity(opacity)
    }

    private func subtitle(for slot: CourseTimeSlot) -> Text {
        if slot.isCancelled {
            return Text(String(localized: "course_card_cancelled")).fontWeight(.semibold)
        }
        let classroom = slot.room.trimmingCharacters(in: .whitespaces)
        let instructor = slot.course.instructor.trimmingCharacters(in: .whitespaces)
        let room = slot.hasChangedRoom && !classroom.isEmpty
            ? Text("\(Image(systemName: "arrow.left.arrow.right")) \(Text(classroom).fontWeight(.semibold))")
                .foregroundStyle(Color.changeInk)
            : Text(classroom)
        switch (classroom.isEmpty, instructor.isEmpty) {
        case (true, true): return Text(verbatim: "")
        case (false, true): return room
        case (true, false): return Text(instructor)
        case (false, false): return Text("\(room) · \(instructor)")
        }
    }

    private var timeRangeColor: Color {
        switch policy.courseColorUsage {
        case .primarySurface: return Color.textPrimary.opacity(0.7)
        case .smallAccent: return .secondary
        }
    }

    private var subtitleColor: Color {
        switch policy.courseColorUsage {
        case .primarySurface: return Color.textPrimary.opacity(0.6)
        case .smallAccent: return .secondary
        }
    }

    private func courseNameColor(for course: SDCourse) -> Color {
        switch policy.courseColorUsage {
        case .primarySurface: return Color.textPrimary
        case .smallAccent: return .primary
        }
    }

    // `en_US_POSIX` keeps the numeric date stable on ROC or Buddhist-calendar devices.
    private static let shortDateLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = AppConstants.taipeiTimeZone
        f.dateFormat = "M/d"
        return f
    }()

    @ViewBuilder
    private static func dateLabel(from date: Date) -> some View {
        ViewThatFits(in: .horizontal) {
            Text(Date.dayWeekdayFormatter.string(from: date))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(shortDateLabelFormatter.string(from: date))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }
}

private struct CourseCardSurfaceModifier: ViewModifier {
    let tint: Color
    let policy: VisualStylePolicy
    private let shape = RoundedRectangle(cornerRadius: 16)

    func body(content: Content) -> some View {
        switch policy.courseColorUsage {
        case .primarySurface:
            TintedGlassSurface(tint: tint, shape: shape) { content }
        case .smallAccent:
            NeutralCardSurface(shape: shape) { content }
        }
    }
}

private struct TintedGlassSurface<S: Shape, InnerContent: View>: View {
    let tint: Color
    let shape: S
    @ViewBuilder let content: () -> InnerContent

    var body: some View {
        if #available(iOS 26, *) {
            content().glassEffect(.regular.tint(tint.opacity(0.6)), in: shape)
        } else {
            content()
                .background(tint.opacity(0.55), in: shape)
                .background(.ultraThinMaterial, in: shape)
        }
    }
}

private struct NeutralCardSurface<S: InsettableShape, InnerContent: View>: View {
    let shape: S
    @ViewBuilder let content: () -> InnerContent

    var body: some View {
        content()
            .background(Color(.secondarySystemGroupedBackground), in: shape)
            .overlay(
                shape.strokeBorder(Color.textPrimary.opacity(0.08), lineWidth: 0.5)
            )
    }
}
