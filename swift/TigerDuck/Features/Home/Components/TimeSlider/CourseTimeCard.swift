import SwiftUI

struct CourseTimeCard: View {
    let state: CourseState
    let weekday: Int
    let onSelect: ((SDCourse) -> Void)?
    @State private var swipeOffset: CGFloat = 0

    var body: some View {
        HStack(spacing: 8) {
            switch state {
            case .inClass(let course):
                swippableCard(course: course, opacity: 1.0)
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
    private func swippableCard(course: SDCourse, opacity: Double) -> some View {
        ZStack(alignment: .trailing) {
            HStack {
                Spacer()
                Image(systemName: course.isSkipped(on: Date()) ? "arrow.uturn.backward" : "figure.walk")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .padding(.trailing, 24)
            }

            cardContent(course: course, opacity: opacity)
                .offset(x: swipeOffset)
                .gesture(
                    DragGesture(minimumDistance: 20)
                        .onChanged { value in
                            if value.translation.width < 0 {
                                swipeOffset = value.translation.width
                            }
                        }
                        .onEnded { value in
                            if value.translation.width < -60 {
                                course.toggleSkip(on: Date())
                            }
                            withAnimation(.smooth(duration: 0.25)) {
                                swipeOffset = 0
                            }
                        }
                )
        }
    }

    @ViewBuilder
    private func cardContent(course: SDCourse, opacity: Double) -> some View {
        let isSkipped = course.isSkipped(on: Date())
        VStack(alignment: .leading, spacing: 4) {
            if let timeRange = course.timeRange(for: weekday) {
                Text(timeRange)
                    .font(.caption.bold())
                    .foregroundStyle(course.color)
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
}
