import SwiftUI

struct CourseTimeCard: View {
    let state: CourseState
    /// Hands back the full slot (not just the course) so callers can preserve
    /// the precise day + start/end of the tapped period — the detail sheet
    /// uses both to render the right time range and weekday-specific classroom.
    let onSelect: ((CourseTimeSlot) -> Void)?
    var policy: VisualStylePolicy = VisualStylePolicy(preset: .default)

    var body: some View {
        // EqualHeightHStack pins the .inClass and .between branches to the tallest
        // height seen during Home's lifetime, so the slot does not jump as the slider
        // moves between states with slightly different content heights.
        EqualHeightHStack(alignment: .top, spacing: 8) {
            switch state {
            case .inClass(let slots):
                // Conflicting slots get a card each and share the width like `.between`'s
                // pair, so each course shows and opens its own room and assignments. A lone
                // slot keeps its natural width rather than the overlap's layout.
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
        let weekday = slot.date.scheduleWeekday
        let isToday = AppConstants.taipeiCalendar.isDateInToday(slot.date)

        HStack(alignment: .top, spacing: 10) {
            // Accent stripe — shows the course color as a small accent in
            // the iOS preset, and is hidden in the default preset where
            // the entire surface is already course-colored.
            if policy.courseColorUsage == .smallAccent {
                RoundedRectangle(cornerRadius: 2)
                    .fill(course.color)
                    .frame(width: 3)
                    .padding(.vertical, 2)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    // This slot's own block, not `course.timeRange(for:)`: that spans the
                    // day's first to last period and would mismatch the card when a course
                    // has split same-day blocks.
                    Text("\(slot.start.timeString) - \(slot.end.timeString)")
                        .font(.caption.bold())
                        .foregroundStyle(timeRangeColor)
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
                    .foregroundStyle(courseNameColor(for: course))
                    .lineLimit(1)
                Text(subtitle(for: course, weekday: weekday))
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
        // Hit shape + tap handling come from `scrollSafeTapAction` in
        // `cardContent`, which wraps this surface in a `Button`.
    }

    private func subtitle(for course: SDCourse, weekday: Int) -> String {
        let classroom = course.classroom(for: weekday).trimmingCharacters(in: .whitespaces)
        let instructor = course.instructor.trimmingCharacters(in: .whitespaces)
        switch (classroom.isEmpty, instructor.isEmpty) {
        case (true, true): return ""
        case (false, true): return classroom
        case (true, false): return instructor
        case (false, false): return "\(classroom) · \(instructor)"
        }
    }

    private var timeRangeColor: Color {
        switch policy.courseColorUsage {
        case .primarySurface: return .white.opacity(0.7)
        case .smallAccent: return .secondary
        }
    }

    private var subtitleColor: Color {
        switch policy.courseColorUsage {
        case .primarySurface: return .white.opacity(0.6)
        case .smallAccent: return .secondary
        }
    }

    private func courseNameColor(for course: SDCourse) -> Color {
        switch policy.courseColorUsage {
        case .primarySurface: return .white
        case .smallAccent: return .primary
        }
    }

    // The pinned gregorian calendar, and `en_US_POSIX` in the short form, keep the
    // numeric date stable on ROC or Buddhist-calendar devices. The EEEEE weekday
    // still follows `Locale.current`; only the calendar arithmetic is overridden.
    private static let dateLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = AppConstants.taipeiTimeZone
        f.dateFormat = "M/d (EEEEE)"
        return f
    }()

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
            Text(dateLabelFormatter.string(from: date))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(shortDateLabelFormatter.string(from: date))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }
}

// MARK: - Surface

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
                shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
    }
}
