import SwiftUI

struct CourseTimeCard: View {
    let state: CourseState
    let onSelect: ((SDCourse) -> Void)?

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

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(course.timeRange(for: weekday) ?? "──:── - ──:──")
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.7))
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
                .foregroundStyle(.white)
                .lineLimit(1)
            Text("\(course.classroom(for: weekday)) · \(course.instructor)")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(TintedGlassModifier(tint: course.color))
        .opacity(opacity)
        .onTapGesture { onSelect?(course) }
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
                .foregroundStyle(.white.opacity(0.5))
            Text(shortDateLabelFormatter.string(from: date))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
        }
        .lineLimit(1)
    }
}

// MARK: - Availability Helpers

private struct TintedGlassModifier: ViewModifier {
    let tint: Color
    private let shape = RoundedRectangle(cornerRadius: 16)

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular.tint(tint.opacity(0.6)), in: shape)
        } else {
            content
                .background(tint.opacity(0.55), in: shape)
                .background(.ultraThinMaterial, in: shape)
        }
    }
}

