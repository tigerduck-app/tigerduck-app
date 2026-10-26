import Defaults
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct CourseDetailSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let course: SDCourse
    let assignments: [SDAssignment]
    var timeRange: String? = nil
    var weekday: Int? = nil
    var periods: [String]? = nil
    var moodlePath: Binding<[MoodleCourseRoute]>? = nil
    var showsMoodle = true

    @State private var ownMoodlePath: [MoodleCourseRoute] = []
    @State private var moodle: MoodleCourseStore?
    @State private var moodleAttempt = 0
    @State private var syllabus: CourseSyllabus?
    #if os(iOS)
    @State private var detent: PresentationDetent = .medium
    #endif

    @State private var codeCopied = false
    @State private var copyFeedback = 0

    var body: some View {
        NavigationStack(path: routes) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.lg) {
                        headerSection
                        emphasisCards
                        secondaryInfo
                        assignmentsSection
                    }
                    if let moodle {
                        MoodleCourseSection(store: moodle, policy: appState.visualStylePolicy)
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
                    CourseSyllabusView(syllabus: syllabus, policy: appState.visualStylePolicy)
                        .moodleLinkOpening()
                } else if let moodle {
                    moodleDestination(route, store: moodle)
                        .moodleLinkOpening()
                }
            }
        }
        .task(id: MoodleStoreKey(
            courseNo: course.courseNo, attempt: moodleAttempt, generation: appState.authService.loginGeneration
        )) {
            moodle = makeMoodleStore()
        }
        .task(id: [course.semester, course.courseNo]) {
            syllabus = nil
            let loaded = await loadSyllabus()
            if !Task.isCancelled { syllabus = loaded }
        }
        .onChange(of: appState.authService.loginGeneration) {
            routes.wrappedValue = []
        }
        .onReceive(NotificationCenter.default.publisher(for: AppConstants.dataDidUpdate)) { _ in
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
        let generation: Int
    }

    private var routes: Binding<[MoodleCourseRoute]> {
        moodlePath ?? $ownMoodlePath
    }

    @ViewBuilder
    private func moodleDestination(_ route: MoodleCourseRoute, store: MoodleCourseStore) -> some View {
        switch route {
        case .announcements:
            MoodleAnnouncementsView(store: store) { routes.wrappedValue.append($0) }
        case .announcement(let discussion):
            MoodleAnnouncementView(store: store, discussion: discussion) { routes.wrappedValue.append($0) }
        case .materials:
            MoodleMaterialsView(store: store, policy: appState.visualStylePolicy)
        case .grades:
            MoodleGradesView(store: store)
        case .members:
            MoodleMembersView(store: store, policy: appState.visualStylePolicy) { routes.wrappedValue.append($0) }
        case .member(let member):
            MoodleMemberView(store: store, member: member)
        case .forums:
            MoodleForumsView(store: store) { routes.wrappedValue.append($0) }
        case .forum(let forum):
            MoodleForumView(store: store, forum: forum) { routes.wrappedValue.append($0) }
        case .discussion(let discussion, let forum):
            MoodleDiscussionView(store: store, discussion: discussion, forum: forum)
        case .assignments:
            MoodleAssignmentsView(
                store: store, policy: appState.visualStylePolicy, refresh: refreshAssignments, open: openAssignment
            )
        case .assignment(let entry):
            #if os(iOS)
            MoodleAssignmentView(
                store: store, entry: entry, courseName: course.displayName,
                policy: appState.visualStylePolicy, accent: appState.accentColor
            )
            #else
            EmptyView()
            #endif
        case .syllabus:
            EmptyView()
        }
    }

    /// Nil for a course without a term or course number, such as one the student added by hand,
    /// and when the fetch fails or the syllabus has nothing to show.
    private func loadSyllabus() async -> CourseSyllabus? {
        guard !course.semester.isEmpty, !course.courseNo.isEmpty else { return nil }
        let syllabus = try? await CourseLookupService.syllabus(
            semester: course.semester,
            courseNo: course.courseNo,
            language: LanguageManager.resolvedCourseApiLanguage(appLanguage: Defaults[.appLanguage])
        )
        return syllabus?.hasContent == true ? syllabus : nil
    }

    private func makeMoodleStore() -> MoodleCourseStore? {
        guard showsMoodle, let idnumber = course.moodleIdNumber, !idnumber.isEmpty,
              let courseId = DataCache.shared.lookupMoodleCourseId(idnumber: idnumber),
              let context = MoodleCacheContext.signedIn(appState.authService) else { return nil }
        let term = SDCourse.semesterPrefix(ofMoodleId: idnumber)
        let idMap = DataCache.shared.loadMoodleCourseIdMap()
        let termCourseIds = idMap
            .filter { term != nil && SDCourse.semesterPrefix(ofMoodleId: $0.key) == term }
            .map(\.value)
        return MoodleCourseStore(
            courseId: courseId,
            termCourseIds: termCourseIds,
            courseCodes: Self.moodleCourseCodes(
                idnumber: idnumber, courseNo: course.courseNo, courseId: courseId, idMap: idMap
            ),
            context: context
        )
    }

    static func moodleCourseCodes(idnumber: String, courseNo: String, courseId: Int, idMap: [String: Int]) -> [String] {
        let idnumbers = [idnumber] + idMap.filter { $0.value == courseId }.map(\.key)
        return idnumbers + idnumbers.map(SDCourse.courseNoFromMoodleId) + [courseNo]
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

    private var emphasisCards: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: TigerDuckTheme.Spacing.md))
            : AnyLayout(HStackLayout(spacing: TigerDuckTheme.Spacing.md))

        return layout {
            EmphasisCard(
                label: String(localized: "course_detail_classroom_label"),
                value: classroomValue,
                policy: appState.visualStylePolicy
            )
            EmphasisCard(
                label: String(localized: "course_detail_time_label"),
                value: timeValue,
                policy: appState.visualStylePolicy
            )
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    private var classroomValue: String {
        let resolved = Self.classroom(of: course, weekday: weekday, periods: periods)
        return resolved.isEmpty ? "—" : resolved
    }

    static func classroom(of course: SDCourse, weekday: Int?, periods: [String]?) -> String {
        guard let weekday else { return SDCourse.dedup(course.classroom) }
        guard let periods, !periods.isEmpty else { return course.classroom(for: weekday) }
        return course.classroom(weekday: weekday, periods: periods)
    }

    private var timeValue: String {
        if let timeRange, !timeRange.isEmpty { return timeRange }
        if let weekday, let derived = course.timeRange(for: weekday) { return derived }
        return "—"
    }

    private var secondaryInfo: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.md) {
            InfoRow(
                label: String(localized: "course_detail_instructor_label"),
                value: course.instructor.isEmpty ? "—" : course.instructor
            )
            InfoRow(
                label: String(localized: "course_detail_code_label"),
                value: course.courseNo,
                copied: codeCopied,
                onTap: copyCourseCode
            )
            // Only general-education courses carry a dimension; for every
            // other course the portal sends an empty string and the row
            // would be a label with nothing beside it.
            if !course.dimension.isEmpty {
                InfoRow(
                    label: String(localized: "course_detail_dimension_label"),
                    value: course.dimension
                )
            }
            if let duration = durationText {
                InfoRow(
                    label: String(localized: "course_detail_duration_label"),
                    value: duration
                )
            }
            if let requireOption = Self.requireOptionText(course.requireOption) {
                InfoRow(
                    label: String(localized: "course_detail_require_option_label"),
                    value: requireOption
                )
            }
            InfoRow(
                label: String(localized: "course_detail_credits_label"),
                value: course.credits.creditsText
            )
            InfoRow(
                label: String(localized: "course_detail_enrollment_label"),
                value: "\(course.enrolledCount) / \(course.maxCount)"
            )
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .sensoryFeedback(.success, trigger: copyFeedback)
    }

    /// QueryCourse spells `AllYear` as "F" (spans the academic year) or "H"
    /// (a single semester). Anything else — including the empty string a row
    /// cached before this field existed carries — says nothing, so the row
    /// is left out rather than shown blank.
    private var durationText: String? {
        switch course.allYear.uppercased() {
        case "F": return String(localized: "course_detail_duration_full_year")
        case "H": return String(localized: "course_detail_duration_one_semester")
        default: return nil
        }
    }

    /// QueryCourse's `RequireOption`, "R" required or "E" elective. Anything else, such as the
    /// empty string of a row merged from another device, says nothing, so the row is left out.
    static func requireOptionText(_ requireOption: String) -> String? {
        switch requireOption.uppercased() {
        case "R": return String(localized: "course_detail_require_option_required")
        case "E": return String(localized: "course_detail_require_option_elective")
        default: return nil
        }
    }

    @ViewBuilder
    private var assignmentsSection: some View {
        if !assignments.isEmpty {
            Divider().background(Color.textSecondary)
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)

            Text(String(localized: "course_detail_incomplete_assignments"))
                .font(TigerDuckTheme.Typography.headline)
                .foregroundStyle(Color.textPrimary)
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)

            ForEach(Array(assignments.enumerated()), id: \.element.assignmentId) { _, assignment in
                Button {
                    openListed(assignment)
                } label: {
                    HStack {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(assignment.displayTitle)
                                .font(TigerDuckTheme.Typography.body)
                                .foregroundStyle(Color.textPrimary)
                            Text(String(format: String(localized: "course_detail_due_prefix"), assignment.dueDate.shortDateString))
                                .font(TigerDuckTheme.Typography.caption)
                                .foregroundStyle(assignment.isOverdue ? Color.badgeRed : Color.textSecondary)
                        }
                        Spacer()
                        Image(systemName: Self.assignmentAccessory)
                            .foregroundStyle(Color.textSecondary)
                            .font(.caption)
                    }
                    .cardPadding()
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .glassCard()
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            }
        }
    }

    #if os(macOS)
    private static let assignmentAccessory = "arrow.up.right.square"
    #else
    private static let assignmentAccessory = "chevron.right"
    #endif

    private func openListed(_ assignment: SDAssignment) {
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
        _ = await AppServiceBridge.fetchAssignments(authService: appState.authService, recheckSubmissions: true)
        NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
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

    private func copyCourseCode() {
        #if canImport(UIKit)
        UIPasteboard.general.string = course.courseNo
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(course.courseNo, forType: .string)
        #endif
        copyFeedback += 1
        AccessibilityNotification.Announcement(
            String(localized: "course_detail_code_copied")
        ).post()
        let generation = copyFeedback
        withAnimation { codeCopied = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard copyFeedback == generation else { return }
            withAnimation { codeCopied = false }
        }
    }
}

private struct EmphasisCard: View {
    let label: String
    let value: String
    let policy: VisualStylePolicy

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
            Text(label)
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .allowsTightening(true)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity)
        .padding(TigerDuckTheme.Spacing.md)
        .presetCard(policy: policy)
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    var copied: Bool = false
    var onTap: (() -> Void)? = nil

    var body: some View {
        if let onTap {
            Button(action: onTap) { content }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(label), \(value)"))
                .accessibilityHint(Text(String(localized: "course_detail_copy_code")))
        } else {
            content
        }
    }

    private var content: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(Color.textSecondary)
            Spacer()
            if onTap != nil {
                if copied {
                    Image(systemName: "checkmark")
                        .font(TigerDuckTheme.Typography.caption)
                        .foregroundStyle(.tint)
                } else {
                    Image(systemName: "doc.on.doc")
                        .font(TigerDuckTheme.Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                }
            }
            Text(value)
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        // Without this the button only reacts on the label and value text,
        // not on the gap between them — which is most of the row.
        .contentShape(Rectangle())
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
