#if os(iOS)
import MarkdownUI
import SwiftUI

/// One assignment: its course and title, a card with the due time and the group, its description
/// and attachments, then what the account handed in with the comments on it, and the grade. The
/// app submits nothing, so the button at the foot opens the assignment on Moodle. The page fetches
/// the submission when it opens and on each return to the app, and shows the last copy meanwhile.
struct MoodleAssignmentView: View {
    let store: MoodleCourseStore
    let entry: MoodleCourseAssignments.Entry
    let courseName: String
    let policy: VisualStylePolicy
    let accent: Color

    @Environment(\.openURL) private var openURL
    @Environment(\.openMoodleLink) private var openMoodleLink
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    /// Coming back from a preview or a pushed screen is not another opening.
    @State private var didOpen = false
    @State private var files = MoodleFileOpener()
    @ScaledMetric(relativeTo: .title) private var tileWidth: CGFloat = 56
    @ScaledMetric(relativeTo: .title) private var tileHeight: CGFloat = 60
    @ScaledMetric(relativeTo: .largeTitle) private var scoreSize: CGFloat = 44

    private var record: MoodleAssignmentRecord { entry.record }

    var body: some View {
        let feed = store.assignments.submission(of: record)
        let submission = feed.value
        let isSubmitted = Self.isSubmitted(record: record, listed: entry.listed, submission: submission)
        let description = MoodleHTMLText.markdown(fromHTML: record.intro)
        ScrollView {
            VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xl) {
                header
                summaryCard(isSubmitted: isSubmitted, group: submission?.groupName)
                if !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    section(String(localized: "assignment_detail_description")) { markdown(description) }
                }
                if !record.introAttachments.isEmpty {
                    section(String(localized: "school_mail_attachments")) {
                        fileRows(record.introAttachments.map { MoodleFileRef(file: $0, owner: .module(record.cmId)) })
                            .presetCard(policy: policy)
                    }
                }
                if !record.noSubmissions {
                    Divider().background(Color.textSecondary)
                    submissionSection(feed, badge: Self.badge(
                        isSubmitted: isSubmitted,
                        submittedAt: Self.submittedAt(of: entry.listed, submission: submission),
                        due: record.dueDate
                    ))
                }
                if let grade = submission?.grade {
                    gradeSection(grade)
                        .padding(.top, TigerDuckTheme.Spacing.sm)
                }
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .padding(.top, TigerDuckTheme.Spacing.xxl)
            .padding(.bottom, TigerDuckTheme.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.backgroundPrimary)
        .safeAreaInset(edge: .bottom) {
            if !record.noSubmissions { submitButton }
        }
        .moodleArticleChrome()
        .task {
            guard !didOpen else { return }
            didOpen = true
            await store.assignments.refreshSubmission(of: record)
        }
        // A submission made on Moodle shows once the app is back.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await store.assignments.refreshSubmission(of: record) }
        }
        .moodleFilePresentation(files)
    }

    /// The submission's time, and before the first fetch answers, the one the assignment round
    /// found.
    static func submittedAt(of listed: SDAssignment?, submission: MoodleAssignmentSubmission?) -> Date? {
        guard let submission else { return listed?.isCompleted == true ? listed?.submittedAt : nil }
        return submission.submittedAt
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
            Text(courseName)
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
            Text(record.name.decodingHTMLEntities())
                .font(TigerDuckTheme.Typography.title)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHeading(.h1)
        }
    }

    // MARK: - Due time and group

    @ViewBuilder
    private func summaryCard(isSubmitted: Bool?, group: String?) -> some View {
        if record.dueDate != nil || group != nil {
            VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.md) {
                if let due = record.dueDate {
                    // The time left moves on while the page stays open.
                    TimelineView(.everyMinute) { _ in
                        deadline(due, Self.deadline(due: due, isSubmitted: isSubmitted, now: AppClock.now()))
                    }
                }
                if let group {
                    if record.dueDate != nil { Divider() }
                    groupRow(group)
                }
            }
            .padding(TigerDuckTheme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .presetCard(policy: policy)
        }
    }

    /// At accessibility sizes the tile goes above the times, which beside it would have no room.
    private func deadline(_ due: Date, _ deadline: Deadline) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: TigerDuckTheme.Spacing.md))
            : AnyLayout(HStackLayout(spacing: TigerDuckTheme.Spacing.md))
        return layout {
            calendarTile(due, isOverdue: deadline.isOverdue)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "assignment_detail_due"))
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
                Text(Self.weekdayTimeText(due))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.textPrimary)
                Text(deadline.text)
                    .font(.footnote.weight(deadline.isEmphasized ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(deadline.tint)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "assignment_detail_due"))
        .accessibilityValue("\(Self.timeText(due)), \(deadline.text)")
    }

    /// Grows with the text instead of clipping it.
    private func calendarTile(_ due: Date, isOverdue: Bool) -> some View {
        VStack(spacing: 0) {
            Text(Self.monthText(due))
                .font(TigerDuckTheme.Typography.caption.weight(.semibold))
                .foregroundStyle(isOverdue ? Color.badgeRed : accent)
            Text(verbatim: String(AppConstants.taipeiCalendar.component(.day, from: due)))
                .font(.title.bold())
                .monospacedDigit()
                .foregroundStyle(Color.textPrimary)
        }
        .fixedSize()
        .padding(TigerDuckTheme.Spacing.xs)
        .frame(minWidth: tileWidth, minHeight: tileHeight)
        .background(
            isOverdue ? Color.badgeRed.opacity(0.16) : Color.textPrimary.opacity(0.07),
            in: RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md)
        )
    }

    /// At accessibility sizes the group's name goes under its label, which would leave it no room.
    private func groupRow(_ group: String) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: TigerDuckTheme.Spacing.md))
        let alignment: Alignment = dynamicTypeSize.isAccessibilitySize ? .leading : .trailing
        return layout {
            HStack(spacing: TigerDuckTheme.Spacing.sm) {
                Image(systemName: "person.2")
                    .accessibilityHidden(true)
                Text(String(localized: "assignment_detail_group"))
            }
            .font(.subheadline)
            .foregroundStyle(Color.textSecondary)
            .fixedSize()
            Text(group)
                .font(TigerDuckTheme.Typography.headline)
                .foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                .frame(maxWidth: .infinity, alignment: alignment)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Submission

    private func submissionSection(_ feed: MoodleFeed<MoodleAssignmentSubmission>, badge: Badge?) -> some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.md) {
            // The badge goes under the heading when it does not fit beside it.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: TigerDuckTheme.Spacing.md) {
                    sectionTitle(String(localized: "assignment_detail_submission"))
                    Spacer(minLength: 0)
                    if let badge { badgeView(badge) }
                }
                VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
                    sectionTitle(String(localized: "assignment_detail_submission"))
                    if let badge { badgeView(badge) }
                }
            }
            if let submission = feed.value {
                if Self.showsCard(submission) { submissionCard(submission) }
                if let comments = submission.comments, !comments.isEmpty { commentList(comments) }
            } else {
                MoodleFirstLoadView(
                    failure: feed.isRefreshing ? nil : feed.failure,
                    retry: { await store.assignments.refreshSubmission(of: record) }
                )
            }
        }
    }

    private func badgeView(_ badge: Badge) -> some View {
        HStack(spacing: TigerDuckTheme.Spacing.xs) {
            Image(systemName: badge.symbol)
                .font(.caption2.weight(.bold))
                .accessibilityHidden(true)
            Text(badge.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(badge.tint)
        .padding(.horizontal, TigerDuckTheme.Spacing.md)
        .padding(.vertical, TigerDuckTheme.Spacing.xs)
        .background(badge.tint.opacity(0.16), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    /// The time it was handed in, or a draft's, over the files and the text.
    private func submissionCard(_ submission: MoodleAssignmentSubmission) -> some View {
        let refs = submission.files.map { MoodleFileRef(file: $0, owner: .submission(record.assignId)) }
        let text = submission.onlineText
        return VStack(alignment: .leading, spacing: 0) {
            timeRow(
                submission.isSubmitted
                    ? String(localized: "assignment_detail_submitted_at")
                    : String(localized: "assignment_detail_draft"),
                submission.modified.map { Self.timeText($0) }
            )
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .padding(.top, TigerDuckTheme.Spacing.md)
            .padding(.bottom, refs.isEmpty && text == nil ? TigerDuckTheme.Spacing.md : 0)
            fileRows(refs)
            if let text {
                if !refs.isEmpty {
                    Divider().padding(.leading, MoodleFileRow.textInset)
                }
                markdown(MoodleHTMLText.markdown(fromHTML: text))
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                    .padding(.vertical, TigerDuckTheme.Spacing.md)
            }
        }
        .presetCard(policy: policy)
    }

    private func commentList(_ comments: [MoodleSubmissionComment]) -> some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.md) {
            Text(String(localized: "assignment_detail_comments"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.textSecondary)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(comments.enumerated()), id: \.element.id) { index, comment in
                    if index > 0 {
                        Divider().padding(.leading, TigerDuckTheme.Spacing.lg)
                    }
                    VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
                        Text([MoodlePersonName.displayName(comment.authorName), Self.timeText(comment.created)]
                            .filter { !$0.isEmpty }
                            .joined(separator: " · "))
                            .font(TigerDuckTheme.Typography.caption)
                            .monospacedDigit()
                            .foregroundStyle(Color.textSecondary)
                        markdown(MoodleHTMLText.markdown(fromHTML: comment.content))
                    }
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                    .padding(.vertical, TigerDuckTheme.Spacing.md)
                }
            }
            .presetCard(policy: policy)
        }
        .padding(.top, TigerDuckTheme.Spacing.xs)
    }

    // MARK: - Grade

    private func gradeSection(_ grade: MoodleAssignmentGrade) -> some View {
        section(String(localized: "assignment_detail_grade")) {
            VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.md) {
                if let shown = grade.grade {
                    scoreRow(Self.score(of: shown))
                }
                if let gradedAt = grade.gradedAt {
                    timeRow(String(localized: "assignment_detail_graded_at"), Self.timeText(gradedAt))
                }
                if let feedback = grade.feedback {
                    if grade.grade != nil || grade.gradedAt != nil { Divider() }
                    VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
                        Text(String(localized: "assignment_detail_feedback"))
                            .font(.footnote)
                            .foregroundStyle(Color.textSecondary)
                        markdown(MoodleHTMLText.markdown(fromHTML: feedback))
                    }
                }
            }
            .padding(TigerDuckTheme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .presetCard(policy: policy)
        }
    }

    private func scoreRow(_ score: Score) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: TigerDuckTheme.Spacing.sm) {
            Text(score.value)
                .font(.system(size: scoreSize, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(accent)
            if let max = score.max {
                Text(verbatim: "/ \(max)")
                    .font(.title3)
                    .monospacedDigit()
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(score.spoken)
    }

    // MARK: - Shared pieces

    /// A label and its time in small grey type. At accessibility sizes the time goes under its
    /// label, which would leave it no room.
    private func timeRow(_ label: String, _ time: String?) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        return layout {
            Text(label)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let time {
                Text(time)
                    .monospacedDigit()
                    .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
            }
        }
        .font(.footnote)
        .foregroundStyle(Color.textSecondary)
        .accessibilityElement(children: .combine)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.md) {
            sectionTitle(title)
            content()
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(TigerDuckTheme.Typography.headline)
            .foregroundStyle(Color.textPrimary)
            .accessibilityAddTraits(.isHeader)
    }

    private func markdown(_ text: String) -> some View {
        Markdown(BulletinBodyRenderer.normalize(text))
            .markdownTheme(.bulletin(accent: accent))
            .environment(\.openURL, OpenURLAction { url in
                files.forgetPendingOpen()
                openMoodleLink(url)
                return .handled
            })
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fileRows(_ refs: [MoodleFileRef]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(refs.enumerated()), id: \.offset) { index, ref in
                if index > 0 {
                    Divider().padding(.leading, MoodleFileRow.textInset)
                }
                MoodleFileRow(
                    title: ref.file.name,
                    file: ref.file,
                    state: store.downloadState(of: ref.file, in: ref.owner),
                    tap: { files.tap(ref, among: refs, store: store) },
                    share: { files.share(ref, store: store) },
                    openInMoodle: openOnMoodle
                )
            }
        }
    }

    @ViewBuilder
    private var submitButton: some View {
        let label = Text(String(localized: "assignment_detail_submit_on_moodle"))
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity)
        Group {
            if #available(iOS 26, *) {
                Button(action: openOnMoodle) { label }.buttonStyle(.glassProminent)
            } else {
                Button(action: openOnMoodle) { label }.buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.bottom, TigerDuckTheme.Spacing.sm)
    }

    /// The Moodle app where it is installed, else the web page, signed in.
    private func openOnMoodle() {
        files.forgetPendingOpen()
        Task { await openURL(MoodlePage.module("assign", cmid: record.cmId)) }
    }
}

/// An assignment's page opened outside a course detail, with the store of its course.
struct MoodleAssignmentPage: Hashable {
    let entry: MoodleCourseAssignments.Entry
    let store: MoodleCourseStore
    let courseName: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry && lhs.store === rhs.store && lhs.courseName == rhs.courseName
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(entry)
        hasher.combine(ObjectIdentifier(store))
        hasher.combine(courseName)
    }
}
#endif
