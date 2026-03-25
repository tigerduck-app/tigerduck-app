import SwiftUI

struct CourseTimeCard: View {
    let state: CourseState
    let weekday: Int
    let onSelect: ((SDCourse) -> Void)?
    let onSkip: (SDCourse) -> Void

    var body: some View {
        HStack(spacing: 8) {
            switch state {
            case .inClass(let course):
                cardContent(course: course, opacity: 1.0)
                SkipClassButton(course: course, onSkip: onSkip)
            case .between(let prev, let next):
                if let prev {
                    cardContent(course: prev, opacity: 0.5)
                        .frame(maxWidth: .infinity)
                }
                if let next {
                    cardContent(course: next, opacity: 0.5)
                        .frame(maxWidth: .infinity)
                }
            case .beforeFirst(let next):
                cardContent(course: next, opacity: 0.5)
            case .afterLast(let prev):
                cardContent(course: prev, opacity: 0.5)
            }
        }
        .animation(.smooth(duration: 0.35), value: state)
    }

    @ViewBuilder
    private func cardContent(course: SDCourse, opacity: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let timeRange = course.timeRange(for: weekday) {
                Text(timeRange)
                    .font(.caption.bold())
                    .foregroundStyle(course.color)
            }
            Text(course.courseName)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
            Text("\(course.classroom) · \(course.instructor)")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)

            if course.isSkipped(on: Date()) {
                Text("已翹課")
                    .font(.caption2.bold())
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(course.color), in: RoundedRectangle(cornerRadius: 16))
        .opacity(opacity)
        .onTapGesture { onSelect?(course) }
    }
}
