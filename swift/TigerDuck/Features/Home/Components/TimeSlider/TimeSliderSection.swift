import SwiftUI

struct TimeSliderSection: View {
    let courses: [SDCourse]
    var onSelectCourse: ((SDCourse) -> Void)? = nil
    @Environment(AppState.self) private var appState
    @State private var viewModel = TimeSliderViewModel()

    var body: some View {
        VStack(spacing: TigerDuckTheme.Spacing.sm) {
            sectionHeader
            contentArea
        }
        .onAppear {
            viewModel.configure(courses: courses)
        }
        .onChange(of: courses.map(\.courseNo)) {
            viewModel.configure(courses: courses)
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        let state = NTUSTProtectedAccessState(
            isLoggedIn: appState.isNTUSTLoggedIn,
            isEmpty: !viewModel.hasCourses
        )

        switch state {
        case .loginRequired:
            LoginRequiredView(
                layout: .section,
                title: "尚未登入",
                message: "尚未登入，無法顯示今日課程",
                onPrimary: { appState.presentNTUSTLogin() }
            )
        case .content, .empty, .loading, .error:
            Group {
                if viewModel.hasCourses {
                    sliderContent
                } else {
                    emptyState
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var sectionHeader: some View {
        HStack {
            Text("時光機")
                .font(TigerDuckTheme.Typography.headline)
                .foregroundStyle(Color.textPrimary)
            Spacer()
        }
        .overlay(alignment: .trailing) {
            if viewModel.isUserDragging {
                Button("現在") {
                    viewModel.returnToNow()
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .modifier(GlassButtonStyleModifier())
                .transition(.opacity.combined(with: .scale(0.85, anchor: .trailing)))
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.top, TigerDuckTheme.Spacing.md)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isUserDragging)
    }

    private var sliderContent: some View {
        let policy = appState.visualStylePolicy
        return TimelineView(.periodic(from: .now, by: 1)) { context in
            let _ = viewModel.tick(context.date)

            VStack(spacing: 12) {
                // Course card
                CourseTimeCard(
                    state: viewModel.currentCourseState,
                    onSelect: onSelectCourse,
                    policy: policy
                )

                // Time label + track
                VStack(spacing: 6) {
                    timeLabel
                    FluidGlassTrackView(
                        viewModel: viewModel,
                        invertDirection: appState.invertSliderDirection,
                        policy: policy
                    )
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
            Text("目前沒有課程")
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
        f.dateFormat = "M/d (EEEEE) HH:mm"
        return f
    }()
}

// MARK: - Availability Helpers

private struct GlassButtonStyleModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}
