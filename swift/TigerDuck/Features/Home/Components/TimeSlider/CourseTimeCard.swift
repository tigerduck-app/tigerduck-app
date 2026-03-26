import SwiftUI

struct CourseTimeCard: View {
    let state: CourseState
    let onSelect: ((SDCourse) -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            switch state {
            case .inClass(let slot):
                swipeableCard(slot: slot, opacity: 1.0)
            case .between(let prev, let next):
                if let prev {
                    swipeableCard(slot: prev, opacity: 0.5)
                        .frame(maxWidth: .infinity)
                }
                if let next {
                    swipeableCard(slot: next, opacity: 0.5)
                        .frame(maxWidth: .infinity)
                }
            case .beforeFirst(let next):
                swipeableCard(slot: next, opacity: 0.5)
            case .afterLast(let prev):
                swipeableCard(slot: prev, opacity: 0.5)
            }
        }
        .animation(.smooth(duration: 0.35), value: state)
    }

    @ViewBuilder
    private func swipeableCard(slot: CourseTimeSlot, opacity: Double) -> some View {
        SwipeToSkipWrapper(course: slot.course, date: slot.date) {
            cardContent(slot: slot, opacity: opacity)
        }
    }

    @ViewBuilder
    private func cardContent(slot: CourseTimeSlot, opacity: Double) -> some View {
        let course = slot.course
        let weekday = slot.date.scheduleWeekday
        let isSkipped = course.isSkipped(on: slot.date)
        let isToday = Calendar.current.isDateInToday(slot.date)

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(course.timeRange(for: weekday) ?? "──:── - ──:──")
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                if !isToday {
                    Text(Self.dateLabelString(from: slot.date))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            Text(course.courseName)
                .font(.headline)
                .foregroundStyle(isSkipped ? .pink : .white)
                .lineLimit(1)
            Text("\(course.classroom) · \(course.instructor)")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(course.color), in: RoundedRectangle(cornerRadius: 16))
        .opacity(opacity)
        .onTapGesture { onSelect?(course) }
    }

    private static func dateLabelString(from date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_TW")
        f.dateFormat = "M/d (EEE)"
        return f.string(from: date)
    }
}

// MARK: - Swipe-to-Skip Wrapper

private struct SwipeToSkipWrapper<Content: View>: View {
    let course: SDCourse
    let date: Date
    @ViewBuilder let content: Content
    @State private var swipeOffset: CGFloat = 0

    private let threshold: CGFloat = -100

    private var isSkipped: Bool { course.isSkipped(on: date) }
    private var progress: CGFloat { min(1, abs(swipeOffset) / abs(threshold)) }

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack {
                Spacer()
                VStack(spacing: 4) {
                    Image(systemName: isSkipped ? "arrow.uturn.backward" : "figure.walk")
                        .font(.title3.bold())
                    Text(isSkipped ? "取消翹課" : "翹課")
                        .font(.caption2.bold())
                }
                .foregroundStyle(.white)
                .opacity(Double(progress))
                .scaleEffect(0.8 + 0.2 * progress)
                .padding(.trailing, 24)
            }

            content
                .offset(x: swipeOffset)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 30)
                        .onChanged { value in
                            if value.translation.width < 0 {
                                withAnimation(.interactiveSpring) {
                                    swipeOffset = value.translation.width * 0.6
                                }
                            }
                        }
                        .onEnded { _ in
                            if swipeOffset < threshold {
                                withAnimation(.smooth(duration: 0.2)) {
                                    swipeOffset = -400
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                    course.toggleSkip(on: date)
                                    withAnimation(.smooth(duration: 0.25)) {
                                        swipeOffset = 0
                                    }
                                }
                            } else {
                                withAnimation(.smooth(duration: 0.25)) {
                                    swipeOffset = 0
                                }
                            }
                        }
                )
        }
    }
}
