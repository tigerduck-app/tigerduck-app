import Defaults
import SwiftUI
import TigerDuckCore

struct CourseDetailSheet: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.openURL) private var openURL

    let course: CourseStore.Course
    let assignments: [AssignmentStore.Assignment]
    var timeRange: String? = nil
    var weekday: Int? = nil
    var periods: [String]? = nil
    /// A current-term day the sheet shows: its cards carry that day's changes and the coming ones
    /// are listed. Nil, as for another term, shows the weekly timetable alone.
    var date: Date? = nil
    /// The class tapped on Home, which the cards show as it is rather than its whole meeting.
    var slot: CourseTimeSlot? = nil
    var moodlePath: Binding<[MoodleCourseRoute]>? = nil
    var showsMoodle = true
    private let changes = SchoolCalendar.changes

    @State private var ownMoodlePath: [MoodleCourseRoute] = []
    @State private var moodle: MoodleCourseStore?
    @State private var moodleAttempt = 0
    @State private var syllabus: CourseLookup.Syllabus?
    #if os(iOS)
    @State private var detent: PresentationDetent = .medium
    #endif

    var body: some View {
        NavigationStack(path: routes) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.lg) {
                        headerSection
                        CourseDetailRoomAndTime(
                            course: course, timeRange: timeRange, weekday: weekday, periods: periods, meeting: shownMeeting
                        )
                        CourseDetailInfoRows(course: course)
                        CourseDetailChanges(course: course, date: date, shown: shownMeeting, changes: changes)
                        CourseDetailAssignments(assignments: assignments, open: openListed)
                    }
                    if let moodle {
                        MoodleCourseSection(store: moodle, policy: app.preferences.visualStylePolicy)
                    }
                }
                .padding(.top, TigerDuckTheme.Spacing.xl)
                .padding(.bottom, TigerDuckTheme.Spacing.lg)
                .moodleSectionRefresh(moodle)
            }
            .background(Color.backgroundPrimary)
            .moodleLinkOpening()
            #if os(iOS)
            .courseDetailRootBar()
            #endif
            .navigationDestination(for: MoodleCourseRoute.self) { route in
                if case .syllabus(let syllabus) = route {
                    CourseSyllabusView(syllabus: syllabus, policy: app.preferences.visualStylePolicy)
                        .moodleLinkOpening()
                } else if let moodle {
                    CourseMoodleDestination(
                        route: route, store: moodle, courseName: course.displayName, path: routes,
                        refresh: refreshAssignments, openAssignment: openAssignment
                    )
                    .moodleLinkOpening()
                }
            }
        }
        .task(id: MoodleStoreKey(
            courseNo: course.courseNo, attempt: moodleAttempt, signIn: app.authService.session.ticket
        )) {
            moodle = showsMoodle ? CourseMoodleDestination.store(for: course, authService: app.authService) : nil
        }
        .task(id: [course.semester, course.courseNo]) {
            syllabus = nil
            let loaded = await loadSyllabus()
            if !Task.isCancelled { syllabus = loaded }
        }
        .onChange(of: app.authService.session.ticket) {
            routes.wrappedValue = []
        }
        .onChange(of: AppDataRevision.current) {
            if let moodle { moodle.assignments.reload() } else { moodleAttempt += 1 }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large], selection: $detent)
        .onChange(of: routes.wrappedValue) { _, path in
            if !path.isEmpty { detent = .large }
        }
        #endif
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 360)
        #endif
    }

    struct MoodleStoreKey: Equatable {
        let courseNo: String
        let attempt: Int
        let signIn: AccountSession.Ticket
    }

    private var routes: Binding<[MoodleCourseRoute]> {
        moodlePath ?? $ownMoodlePath
    }

    /// Nil for a course without a term or course number, such as one the student added by hand,
    /// and when the fetch fails or the syllabus has nothing to show.
    private func loadSyllabus() async -> CourseLookup.Syllabus? {
        guard !course.semester.isEmpty, !course.courseNo.isEmpty else { return nil }
        let syllabus = try? await CourseLookup.syllabus(
            semester: course.semester,
            courseNo: course.courseNo,
            language: LanguageManager.resolvedCourseApiLanguage(appLanguage: Defaults[.appLanguage])
        )
        return syllabus?.hasContent == true ? syllabus : nil
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.lg) {
            HStack(alignment: .firstTextBaseline, spacing: TigerDuckTheme.Spacing.sm) {
                Text(course.displayName)
                    .font(.title.bold())
                    .foregroundStyle(Color.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let syllabus {
                    Button {
                        routes.wrappedValue.append(.syllabus(syllabus))
                    } label: {
                        Image(systemName: "doc.text.fill")
                            .font(.title2)
                            .foregroundStyle(.tint)
                    }
                    .accessibilityLabel(String(localized: "course_detail_syllabus"))
                }

                if showsMoodle, course.moodleOpenURL != nil {
                    Button(action: openMoodleCourse) {
                        Image(systemName: "arrow.up.right.square.fill")
                            .font(.title2)
                            .foregroundStyle(.tint)
                    }
                    .accessibilityLabel(String(localized: "a11y_course_detail_open_moodle"))
                }
            }

            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.sm)
                .fill(course.color)
                .frame(height: 6)
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    private var shownMeeting: CourseTimeSlot? {
        Self.shownMeeting(of: course, slot: slot, periods: periods, on: date, changes: changes)
    }

    static func shownMeeting(
        of course: CourseStore.Course, slot: CourseTimeSlot?, periods: [String]?, on date: Date?, changes: SchoolCalendar.Changes
    ) -> CourseTimeSlot? {
        let meeting = slot ?? date.flatMap { date in
            (periods ?? course.schedule[date.scheduleWeekday])
                .flatMap { CourseTimeSlot.meeting(of: course, periods: $0, on: date, changes: changes) }
        }
        return meeting.flatMap { $0.changes.isEmpty ? nil : $0 }
    }

    private func openListed(_ assignment: AssignmentStore.Assignment) {
        #if os(iOS)
        if let entry = moodle?.assignments.entry(for: assignment) {
            routes.wrappedValue.append(.assignment(entry))
            return
        }
        #endif
        guard let url = assignment.moodleOpenURL else { return }
        let web = assignment.moodleWebURL
        Task { await openURL(url, fallback: web) }
    }

    private func openAssignment(_ entry: MoodleCourseAssignments.Entry) {
        #if os(iOS)
        routes.wrappedValue.append(.assignment(entry))
        #else
        Task { await openURL(MoodlePage.module("assign", cmid: entry.record.cmId)) }
        #endif
    }

    private func refreshAssignments() async {
        await SchoolRefresh.assignments(authService: app.authService)
    }

    /// On iOS, route through the `moodlemobile://` deep link so Moodle Mobile
    /// picks the user up inside the app, and open the web page when it is not
    /// installed. On macOS no Moodle Mac app exists and the deep link would
    /// surface as an "unhandled URL" error, so the platform-aware
    /// `moodleOpenURL` returns the HTTPS URL instead.
    private func openMoodleCourse() {
        guard let url = course.moodleOpenURL else { return }
        let web = course.moodleWebURL
        Task { await openURL(url, fallback: web) }
    }
}

#if os(iOS)
extension View {
    /// The course detail's own bar. On iOS 26 it is an empty, clear bar with the page drawn under
    /// it as if it were hidden: a bar that a push turns on sits at the sheet's top edge until the
    /// push ends, then drops below the grabber, so every pushed Moodle screen jumped.
    @ViewBuilder
    func courseDetailRootBar() -> some View {
        if #available(iOS 26, *) {
            scrollEdgeEffectHidden(true, for: .top)
                .ignoresSafeArea(.container, edges: .top)
                .toolbar(.visible, for: .navigationBar)
                .toolbarBackground(.hidden, for: .navigationBar)
        } else {
            toolbar(.hidden, for: .navigationBar)
        }
    }
}
#endif
