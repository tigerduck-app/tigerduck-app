import SwiftUI

struct ClassTableView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = ClassTableViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: TigerDuckTheme.Spacing.lg) {
                    // Title
                    HStack {
                        Text("課表")
                            .font(TigerDuckTheme.Typography.title)
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                        NetworkStatusOverlay(loadingState: appState.sessionManager.loadingState)
                        Button {
                            viewModel.showAddCourse = true
                        } label: {
                            Image(systemName: "plus")
                                .foregroundStyle(Color.textSecondary)
                        }
                    }
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                    .padding(.top, TigerDuckTheme.Spacing.md)

                    // Semester picker and credits
                    HStack {
                        Picker("學期", selection: $viewModel.currentSemester) {
                            ForEach(viewModel.availableSemesters, id: \.self) { semester in
                                Text(semester).tag(semester)
                            }
                        }
                        .pickerStyle(.menu)

                        Spacer()

                        Text("共 \(viewModel.totalCredits) 學分")
                            .font(TigerDuckTheme.Typography.body)
                            .foregroundStyle(Color.textSecondary)
                    }
                    .padding(.horizontal)

                    // Today's course cards
                    if !viewModel.todayCourses.isEmpty {
                        SectionHeader(title: "今日課程")
                        TodayCourseCards(
                            courses: viewModel.todayCourses,
                            hasAssignment: viewModel.hasAssignment,
                            onSelect: { viewModel.selectedCourse = $0 }
                        )
                    }

                    // Timetable grid
                    TimetableGridView(viewModel: viewModel)
                }
                .padding(.bottom, TigerDuckTheme.Spacing.xxl)
            }
            .refreshable {
                await viewModel.refresh(authService: appState.authService)
            }
            .background(Color.backgroundPrimary)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .sheet(item: $viewModel.selectedCourse) { course in
                CourseDetailSheet(
                    course: course,
                    assignments: viewModel.assignmentsFor(courseNo: course.courseNo),
                    timeRange: viewModel.selectedCourseTimeRange
                )
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $viewModel.showAddCourse) {
                AddCourseSheet()
            }
        }
        .onAppear {
            viewModel.load(authService: appState.authService)
        }
    }
}
