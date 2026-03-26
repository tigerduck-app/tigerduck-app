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
        .padding(.horizontal, 16)
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
                    onSelect: onSelectCourse
                )

                // Time label + track
                VStack(spacing: 6) {
                    timeLabel
                    switch appState.timeSliderStyle {
                    case .fluidTrack:
                        FluidGlassTrackView(
                            viewModel: viewModel,
                            invertDirection: appState.invertSliderDirection
                        )
                    case .segmentedBar:
                        SegmentedGlassBarView(
                            viewModel: viewModel,
                            invertDirection: appState.invertSliderDirection
                        )
                    }
                }
            }
        }
    }

    private var timeLabel: some View {
        HStack {
            Text(timeLabelString)
                .font(.caption.bold())
                .foregroundStyle(.white.opacity(0.9))
                .contentTransition(.numericText())
            Spacer()
        }
    }

    private var timeLabelString: String {
        let isToday = Calendar.current.isDateInToday(viewModel.selectedTime)
        if isToday {
            return Self.timeFormatter.string(from: viewModel.selectedTime)
        } else {
            return Self.dateTimeFormatter.string(from: viewModel.selectedTime)
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

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_TW")
        f.dateFormat = "M/d (EEE) HH:mm"
        return f
    }()
}
