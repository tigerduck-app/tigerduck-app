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

                    // Today's course cards
                    if !viewModel.todayCourses.isEmpty {
                        VStack(spacing: TigerDuckTheme.Spacing.sm) {
                            SectionHeader(title: "今日課程")
                            TodayCourseCarousel(
                                courses: viewModel.todayCourses,
                                hasAssignment: viewModel.hasAssignment,
                                showProgress: false,
                                onSelect: { viewModel.selectedCourse = $0 }
                            )
                        }
                    }

                    // Semester picker and credits
                    HStack {
                        Picker("學期", selection: $viewModel.currentSemester) {
                            ForEach(viewModel.availableSemesters, id: \.self) { semester in
                                Text(semester).tag(semester)
                            }
                        }
                        .pickerStyle(.menu)

                        Spacer()

                        Text("\(viewModel.totalCredits) 學分")
                        .font(TigerDuckTheme.Typography.body)
                        .foregroundStyle(Color.textSecondary)
                    }
                    .padding(.horizontal)

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
                    timeRange: viewModel.selectedCourseTimeRange,
                    weekday: viewModel.selectedWeekday
                )
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $viewModel.showAddCourse) {
                AddCourseSheet(
                    semester: viewModel.currentSemester,
                    existingCourseNos: Set(viewModel.courses.map(\.courseNo)),
                    onAdd: { viewModel.addCourse($0) }
                )
                .presentationDetents([.medium, .large])
            }
            .alert("重新命名", isPresented: $viewModel.showRenameAlert) {
                TextField("課程名稱", text: $viewModel.renameText)
                Button("確認") {
                    viewModel.confirmRename()
                }
                Button("取消", role: .cancel) {
                    viewModel.courseToRename = nil
                }
            }
        }
        .onAppear {
            viewModel.load(authService: appState.authService)
        }
    }
}
