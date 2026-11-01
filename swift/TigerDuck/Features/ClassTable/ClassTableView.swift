import Defaults
import SwiftUI

struct ClassTableView: View {
    var embedded = false

    @Environment(AppEnvironment.self) private var app
    @State private var viewModel = ClassTableViewModel(
        isClassDay: { SchoolCalendar.isClassDay($0) }
    )
    @State private var export = ClassTableExportState()
    @State private var shareModel: ClassTableShareModel?
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var scroll = ScrollState()
    @State private var tableSwitches = 0
    @Default(.pinTodayCoursesOnClassTable) private var pinsTodayCourses

    var body: some View {
        if embedded {
            content
                .onAppear(perform: start)
                .onChange(of: viewModel.currentSemester) { _, _ in
                    Task { await viewModel.loader.refreshSelectedSemester(authService: app.authService) }
                }
        } else {
            NavigationStack { content }
                .onAppear(perform: start)
                .onChange(of: viewModel.currentSemester) { _, _ in
                    Task { await viewModel.loader.refreshSelectedSemester(authService: app.authService) }
                }
        }
    }

    private func start() {
        viewModel.loader.load()
        viewModel.loader.refreshMissingClassrooms(authService: app.authService)
        viewModel.editor.sync = .live(app)
        Task { await viewModel.loader.warmCachesIfNeeded(authService: app.authService) }
    }

    private var content: some View {
        ScrollView {
                VStack(spacing: TigerDuckTheme.Spacing.lg) {
                    titleBar

                    if let reauthError = app.authService.reauthErrorMessage {
                        NTUSTReauthErrorBanner(
                            message: reauthError,
                            onRetry: {
                                app.authService.clearReauthError()
                                app.router.presentNTUSTLogin()
                            },
                            onDismiss: { app.authService.clearReauthError() }
                        )
                    }

                    switch pageAccessState {
                    case .loginRequired:
                        LoginRequiredView(
                            layout: .page,
                            title: String(localized: "common_not_signed_in"),
                            message: String(localized: "class_table_sign_in_required_message"),
                            onPrimary: { app.router.presentNTUSTLogin() }
                        )
                    case .empty:
                        VStack(spacing: TigerDuckTheme.Spacing.lg) {
                            if pinsTodayCourses, !viewModel.todayCourses.isEmpty {
                                todayCoursesSection
                            }
                            ClassTableSemesterBar(viewModel: viewModel)
                            EmptyStateView(
                                icon: "book.closed",
                                title: String(localized: "home_time_slider_no_courses"),
                                message: viewModel.shownPerson == nil
                                    ? String(localized: "class_table_empty_message")
                                    : String(localized: "class_table_import_lookup_failed")
                            )
                            .padding(.vertical, TigerDuckTheme.Spacing.xxl)
                        }
                    case .content:
                        authenticatedContent
                    }
                }
                .padding(.bottom, TigerDuckTheme.Spacing.xxl)
            }
            .scrollIndicators(.hidden)
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in
                scroll.geometry = geometry
            }
            .refreshable {
                guard viewModel.shownPerson == nil else {
                    await viewModel.refreshShownPerson()
                    return
                }
                viewModel.loader.triggerRefresh(authService: app.authService)
                Task { await SchoolRefresh.courseChanges() }
                if Defaults[.cloudSyncEnabled] {
                    Task { await app.fullSync.sync() }
                }
            }
            .background(Color.backgroundPrimary)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .onChange(of: viewModel.shownTable) { _, _ in
                tableSwitches += 1
                viewModel.showShownTable()
            }
            .onChange(of: app.authService.session.currentSignIn) { _, _ in
                viewModel.editor.closeDialogs()
            }
            .modifier(ClassTableEditDialogs(viewModel: viewModel, editor: viewModel.editor))
            .classTableExportSheets($export)
            .modifier(ClassTablePersonDialogs(people: viewModel.people))
            .classTableShareSheet(model: $shareModel, signIn: app.authService.session.currentSignIn)
    }

    private var pageAccessState: NTUSTProtectedAccessState {
        if viewModel.shownPerson != nil { return viewModel.courses.isEmpty ? .empty : .content }
        return NTUSTProtectedAccessState(signedIn: app.authService.hasStoredCredentials, isEmpty: viewModel.courses.isEmpty)
    }

    private var titleBar: some View {
        HStack {
            Text(String(localized: "feature_class_table"))
                .font(TigerDuckTheme.Typography.title)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            if pageAccessState != .loginRequired {
                HStack(spacing: TigerDuckTheme.Spacing.lg) {
                    SyncStatusDot(servers: ServerKind.classTableSources, lastSynced: .schoolData)
                    ClassTableHeaderMenu(
                        viewModel: viewModel, showsContent: pageAccessState == .content,
                        export: $export, shareModel: $shareModel
                    )
                }
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.top, TigerDuckTheme.Spacing.md)
    }

    private var authenticatedContent: some View {
        VStack(spacing: TigerDuckTheme.Spacing.lg) {
            if pinsTodayCourses, !viewModel.todayCourses.isEmpty {
                todayCoursesSection
            }
            ClassTableSemesterBar(viewModel: viewModel)

            TimetableGridView(viewModel: viewModel, switchCount: tableSwitches, onSwitch: keepRowsInPlace)
        }
    }

    private func keepRowsInPlace(before: TimetableRowTops, after: TimetableRowTops) {
        guard let geometry = scroll.geometry else { return }
        let top = geometry.contentInsets.top
        guard geometry.contentOffset.y + top > 0 else { return }
        let shift = TimetableRowTops.shift(from: before, to: after, visibleTop: top)
        guard shift != 0 else { return }
        // `scrollTo(y:)` counts from the top inset, which `contentOffset` does not.
        scrollPosition.scrollTo(y: max(0, geometry.contentOffset.y + top + shift))
    }

    private var todayCoursesSection: some View {
        VStack(spacing: TigerDuckTheme.Spacing.sm) {
            SectionHeader(title: String(localized: "home_section_today_courses"))
            TodayCourseCarousel(
                courses: viewModel.todayCourses,
                hasAssignment: viewModel.hasAssignment,
                showProgress: false,
                ongoing: viewModel.ongoingCourses,
                onSelect: { viewModel.selection.select(today: $0, now: AppClock.now()) },
                onSelectOngoing: { info in
                    viewModel.selectOngoing(info)
                }
            )
        }
    }
}

private final class ScrollState {
    var geometry: ScrollGeometry?
}
