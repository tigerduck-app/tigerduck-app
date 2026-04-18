import SwiftUI

struct CourseTimeCard: View {
    let state: CourseState
    let onSelect: ((SDCourse) -> Void)?
    var policy: VisualStylePolicy = VisualStylePolicy(preset: .default)

    var body: some View {
        HStack(spacing: 8) {
            switch state {
            case .inClass(let slot):
                cardContent(slot: slot, opacity: 1.0)
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
        let course = slot.course
        let weekday = slot.date.scheduleWeekday
        let isToday = Calendar.current.isDateInToday(slot.date)

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
                    Text(course.timeRange(for: weekday) ?? "──:── - ──:──")
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

                Text(course.courseName)
                    .font(.headline)
                    .foregroundStyle(courseNameColor(for: course))
                    .lineLimit(1)
                Text("\(course.classroom(for: weekday)) · \(course.instructor)")
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
        .onTapGesture { onSelect?(course) }
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

    private static let dateLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_TW")
        f.dateFormat = "M/d (EEEEE)"
        return f
    }()

    private static let shortDateLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_TW")
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
