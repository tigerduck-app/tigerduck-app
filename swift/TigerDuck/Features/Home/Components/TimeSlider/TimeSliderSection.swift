import SwiftUI

struct TimeSliderSection: View {
    let courses: [SDCourse]
    var onSelectCourse: ((SDCourse) -> Void)? = nil
    @Environment(AppState.self) private var appState
    @State private var viewModel = TimeSliderViewModel()

    var body: some View {
        Group {
            if viewModel.hasCourses {
                sliderContent
            } else {
                emptyState
            }
        }
        .onAppear {
            viewModel.configure(courses: courses)
        }
        .onChange(of: courses.map(\.courseNo)) {
            viewModel.configure(courses: courses)
        }
    }

    private var sliderContent: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let _ = viewModel.tick(context.date)

            VStack(spacing: 12) {
                // Course card
                CourseTimeCard(
                    state: viewModel.currentCourseState,
                    weekday: Date().scheduleWeekday,
                    onSelect: onSelectCourse
                )

                // Time labels + track
                VStack(spacing: 6) {
                    timeLabels
                    switch appState.timeSliderStyle {
                    case .fluidTrack:
                        FluidGlassTrackView(viewModel: viewModel)
                    case .segmentedBar:
                        SegmentedGlassBarView(viewModel: viewModel)
                    }
                }
            }
        }
    }

    private var timeLabels: some View {
        HStack {
            Text(Self.timeFormatter.string(from: viewModel.rangeStart))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
            Text(Self.timeFormatter.string(from: viewModel.selectedTime))
                .font(.caption.bold())
                .foregroundStyle(.white.opacity(0.9))
                .contentTransition(.numericText())
            Spacer()
            Text(Self.timeFormatter.string(from: viewModel.rangeEnd))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.title)
                .foregroundStyle(.white.opacity(0.4))
            Text("今日無課")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}
