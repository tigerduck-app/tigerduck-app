import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Modal detail for a single course row. Visual structure:
///   1. Color bar + course title (with optional Moodle jump button)
///   2. Two emphasis cards side-by-side: 教室 (classroom) | 時間 (time)
///   3. Flat InfoRow list: instructor / code / dimension / duration /
///      credits / enrollment
///   4. Outstanding assignments (unchanged)
///
/// The emphasis cards exist because classroom & time are the two fields users
/// glance at most often when tapping a course — they earn their own surface
/// instead of being buried in the same flat list as the metadata rows.
struct CourseDetailSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let course: SDCourse
    let assignments: [SDAssignment]
    var timeRange: String? = nil
    var weekday: Int? = nil

    /// Drives the copy row's glyph; flipped back after a beat so the sheet
    /// does not sit in a "copied" state for as long as it stays open.
    @State private var codeCopied = false
    /// Bumped on every copy so the haptic fires again on a repeat tap.
    @State private var copyFeedback = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.lg) {
                    headerSection
                    emphasisCards
                    secondaryInfo
                    assignmentsSection
                }
                .padding(.top, TigerDuckTheme.Spacing.xl)
                .padding(.bottom, TigerDuckTheme.Spacing.lg)
            }
            .background(Color.backgroundPrimary)
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 360)
        #endif
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.lg) {
            HStack(alignment: .firstTextBaseline, spacing: TigerDuckTheme.Spacing.sm) {
                Text(course.displayName)
                    .font(.title.bold())
                    .foregroundStyle(Color.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if course.moodleOpenURL != nil {
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

    /// Same resolution rule the previous flat layout used: per-weekday lookup
    /// when we know which day this row represents, otherwise the deduped
    /// aggregate string. Empty results render as an em-dash placeholder so
    /// the card always has visible content.
    private var classroomValue: String {
        let resolved = weekday.map { course.classroom(for: $0) } ?? SDCourse.dedup(course.classroom)
        return resolved.isEmpty ? "—" : resolved
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
                    if let url = assignment.moodleOpenURL {
                        openURL(url)
                    }
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
                        Image(systemName: "arrow.up.right.square")
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

    /// On iOS, route through the `moodlemobile://` deep link so Moodle Mobile
    /// picks the user up inside the app. On macOS no Moodle Mac app exists
    /// and the deep link would surface as an "unhandled URL" error, so the
    /// platform-aware `moodleOpenURL` returns the HTTPS URL instead.
    private func openMoodleCourse() {
        guard let url = course.moodleOpenURL else { return }
        openURL(url)
    }

    /// The course code is what students paste into 加退選, the portal search
    /// and group chats, so the row that shows it also hands it over.
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
                // A classroom or a time range is one unit and reads wrong split
                // across lines ("18:25 -" / "22:00"), so it shrinks to fit
                // instead of wrapping. The floor is half size; the caller
                // widens the card at accessibility sizes so that stays enough
                // for a multi-room classroom rather than ellipsising it.
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
