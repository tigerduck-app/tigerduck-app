import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Modal detail for a single course row. Visual structure:
///   1. Color bar and course title, with an optional Moodle jump button
///   2. Two emphasis cards side by side: classroom | time
///   3. Flat InfoRow list: instructor, code, dimension, duration, course type, credits, enrollment
///   4. Outstanding assignments, then the course's Moodle section, whose rows push here
///
/// Classroom and time get their own cards because they are the fields users
/// glance at most when tapping a course, so they stay out of the metadata list.
struct CourseDetailSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let course: SDCourse
    let assignments: [SDAssignment]
    var timeRange: String? = nil
    var weekday: Int? = nil
    /// The tapped block's periods. A course can meet twice a day in two rooms.
    var periods: [String]? = nil
    /// The Mac overlay passes its own, so Escape can go back a screen before it closes.
    var moodlePath: Binding<[MoodleCourseRoute]>? = nil
    /// Off for a course on someone else's class table: the Moodle course is the user's.
    var showsMoodle = true

    @State private var ownMoodlePath: [MoodleCourseRoute] = []
    @State private var moodle: MoodleCourseStore?
    @State private var moodleAttempt = 0
    #if os(iOS)
    @State private var detent: PresentationDetent = .medium
    #endif

    /// Drives the copy row's glyph; flipped back after a beat so the sheet
    /// does not sit in a "copied" state for as long as it stays open.
    @State private var codeCopied = false
    /// Bumped on every copy so the haptic fires again on a repeat tap.
    @State private var copyFeedback = 0

    var body: some View {
        NavigationStack(path: routes) {
            ScrollView {
                // No spacing above the Moodle section: one with no rows adds nothing, and its rows
                // bring their own gap.
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
            // The course summary's links open as a pushed Moodle screen's do.
            .moodleLinkOpening()
            #if os(iOS)
            .courseDetailRootBar()
            #endif
            .navigationDestination(for: MoodleCourseRoute.self) { route in
                if let moodle {
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
        // On iPad another window can sign out or in, and the pushed screens hold the store of the
        // account that opened them.
        .onChange(of: appState.authService.loginGeneration) {
            routes.wrappedValue = []
        }
        .onReceive(NotificationCenter.default.publisher(for: AppConstants.dataDidUpdate)) { _ in
            // A sheet opened before the first sync finds no Moodle course id; a sync may bring it.
            if let moodle { moodle.assignments.reload() } else { moodleAttempt += 1 }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large], selection: $detent)
        // A pushed screen is a list or an article, which the medium height would cut in half.
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
        /// A new sign-in builds a store for its own account, and a sign-out builds none.
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
            MoodleMaterialsView(store: store)
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
            MoodleAssignmentsView(store: store, refresh: refreshAssignments, open: openAssignment)
        case .assignment:
            EmptyView()
        }
    }

    /// Nil for a course with no Moodle course, such as one added by hand, or when signed out.
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

    /// The codes a course's Moodle summary is checked against: every idnumber the Moodle course
    /// `courseId` goes by in `idMap`, since a co-listed course answers to each department's, the
    /// course number in each, and `idnumber` and `courseNo` from the class table.
    static func moodleCourseCodes(idnumber: String, courseNo: String, courseId: Int, idMap: [String: Int]) -> [String] {
        let idnumbers = [idnumber] + idMap.filter { $0.value == courseId }.map(\.key)
        return idnumbers + idnumbers.map(SDCourse.courseNoFromMoodleId) + [courseNo]
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.lg) {
            HStack(alignment: .firstTextBaseline, spacing: TigerDuckTheme.Spacing.sm) {
                Text(course.displayName)
                    .font(.title.bold())
                    .foregroundStyle(Color.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

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

    // MARK: - Emphasis cards

    /// Side by side normally; stacked at accessibility text sizes. Each card
    /// holds its value on one line by shrinking it, and half the sheet is not
    /// enough room to shrink a room list or a time range into at those sizes —
    /// it would have to truncate. Full width is, so the pair gives up being a
    /// pair before the values give up being readable.
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

    /// The block's room when the caller knows the block, else the day's rooms, else every room.
    static func classroom(of course: SDCourse, weekday: Int?, periods: [String]?) -> String {
        guard let weekday else { return SDCourse.dedup(course.classroom) }
        guard let periods, !periods.isEmpty else { return course.classroom(for: weekday) }
        return course.classroom(weekday: weekday, periods: periods)
    }

    /// Prefer the explicit time range supplied by the caller (ClassTable
    /// knows the precise slot). When omitted — e.g. HomeView's TimeSlider
    /// only hands us the weekday — derive it from the course schedule for
    /// that weekday so the card never collapses to a dash unnecessarily.
    private var timeValue: String {
        if let timeRange, !timeRange.isEmpty { return timeRange }
        if let weekday, let derived = course.timeRange(for: weekday) { return derived }
        return "—"
    }

    // MARK: - Secondary info

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

    // MARK: - Assignments (preserved exactly as before)

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
                    openAssignment(assignment)
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
                }
                .buttonStyle(.plain)
                .cardPadding()
                .glassCard()
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            }
        }
    }

    // MARK: - Actions

    /// The Mac opens an assignment on Moodle, as it has no page of its own for it.
    #if os(macOS)
    private static let assignmentAccessory = "arrow.up.right.square"
    #else
    private static let assignmentAccessory = "chevron.right"
    #endif

    /// Its page, pushed here; on Moodle on the Mac, or while the course's Moodle data is not ready.
    private func openAssignment(_ assignment: SDAssignment) {
        #if os(iOS)
        if moodle != nil {
            routes.wrappedValue.append(.assignment(assignment))
            return
        }
        #endif
        guard let url = assignment.moodleOpenURL else { return }
        let web = assignment.moodleWebURL
        Task { await openURL(url, fallback: web) }
    }

    /// A pull on the list, or Refresh on the Mac, asks Moodle about every submission again.
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

    /// The course code is what students paste into course add/drop, the portal
    /// search and group chats, so the row that shows it also hands it over.
    private func copyCourseCode() {
        #if canImport(UIKit)
        UIPasteboard.general.string = course.courseNo
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(course.courseNo, forType: .string)
        #endif
        copyFeedback += 1
        // The checkmark and the haptic are both invisible to VoiceOver, so
        // without this the row gives a screen-reader user no sign the copy
        // happened at all.
        AccessibilityNotification.Announcement(
            String(localized: "course_detail_code_copied")
        ).post()
        let generation = copyFeedback
        withAnimation { codeCopied = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            // A second copy inside the window owns the checkmark now, and
            // this timer would otherwise clear it a beat early — which reads
            // as the repeat tap having done nothing.
            guard copyFeedback == generation else { return }
            withAnimation { codeCopied = false }
        }
    }
}

// MARK: - Emphasis card

/// Big-text card used for the two fields that earn visual emphasis
/// (classroom and time). Label sits small on top, value renders large
/// with a rounded display font so the two cards read as a single
/// at-a-glance pair.
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
                // A classroom or time range reads wrong split across lines, so it shrinks
                // instead of wrapping, never below half size. The caller widens the card at
                // accessibility sizes so a multi-room classroom still fits, not ellipsised.
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

// MARK: - Label/value row

private struct InfoRow: View {
    let label: String
    let value: String
    /// Shows the copy glyph as a checkmark right after a successful copy.
    var copied: Bool = false
    /// Non-nil turns the whole row into a button; the trailing glyph is
    /// what tells the reader the row is tappable at all.
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
        // Baseline-aligned rather than top-aligned so the smaller glyph sits
        // on the value's first line instead of floating above it.
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(Color.textSecondary)
            Spacer()
            // Leading the value, not trailing it: the value is the thing
            // being copied, so the glyph reads as a marker on it rather
            // than as a separate control parked at the row's edge.
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
