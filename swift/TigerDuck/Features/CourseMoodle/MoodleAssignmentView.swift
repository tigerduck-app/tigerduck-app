#if os(iOS)
import MarkdownUI
import SwiftUI

/// One assignment, laid out as an announcement is: its course and title, its times, then its
/// description, attachments, what the account handed in and the comments on it. The app submits
/// nothing, so the button at the foot opens the assignment on Moodle. Opening the page fetches
/// the submission, and until that answers it shows what it showed the last time.
struct MoodleAssignmentView: View {
    let store: MoodleCourseStore
    let assignment: SDAssignment
    let policy: VisualStylePolicy
    let accent: Color

    @Environment(\.openURL) private var openURL
    @Environment(\.openMoodleLink) private var openMoodleLink
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Coming back from a preview or a pushed screen is not another opening.
    @State private var didOpen = false
    @State private var files = MoodleFileOpener()

    var body: some View {
        let record = store.assignments.record(of: assignment)
        let feed = store.assignments.submission(of: assignment)
        let description = record.map { MoodleHTMLText.markdown(fromHTML: $0.intro) } ?? ""
        ScrollView {
            VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.lg) {
                header
                times(feed.value)
                Divider().background(Color.textSecondary)
                if !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    section(String(localized: "assignment_detail_description")) { markdown(description) }
                }
                if let record, !record.introAttachments.isEmpty {
                    section(String(localized: "school_mail_attachments")) {
                        fileCard(record.introAttachments.map { MoodleFileRef(file: $0, owner: .module(record.cmId)) })
                    }
                }
                submission(feed)
                if let comments = feed.value?.comments, !comments.isEmpty {
                    section(String(localized: "assignment_detail_comments")) { commentList(comments) }
                }
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .padding(.top, TigerDuckTheme.Spacing.xxl)
            .padding(.bottom, TigerDuckTheme.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.backgroundPrimary)
        .safeAreaInset(edge: .bottom) { submitButton }
        .moodleArticleChrome()
        .task {
            guard !didOpen else { return }
            didOpen = true
            await store.assignments.refreshSubmission(of: assignment)
        }
        .moodleFilePresentation(files)
    }

    /// The submission's time, and before the first fetch answers, the one the assignment round
    /// found.
    static func submittedAt(of assignment: SDAssignment, submission: MoodleAssignmentSubmission?) -> Date? {
        guard let submission else { return assignment.isCompleted ? assignment.submittedAt : nil }
        return submission.submittedAt
    }

    /// Only for a submission with nothing handed in that is not submitted; one submitted with
    /// nothing in it shows no line.
    static func showsNotSubmitted(_ submission: MoodleAssignmentSubmission) -> Bool {
        !submission.isSubmitted && submission.files.isEmpty && submission.onlineText == nil
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
            Text(assignment.displayCourseName)
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
            Text(assignment.displayTitle)
                .font(TigerDuckTheme.Typography.title)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHeading(.h1)
        }
    }

    private func times(_ submission: MoodleAssignmentSubmission?) -> some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            timeRow(String(localized: "assignment_detail_due"), assignment.dueDate.absoluteTimeString)
            if let submittedAt = Self.submittedAt(of: assignment, submission: submission) {
                timeRow(String(localized: "assignment_detail_submitted_at"), submittedAt.absoluteTimeString)
            }
            if let group = submission?.groupName {
                timeRow(String(localized: "assignment_detail_group"), group)
            }
        }
    }

    /// At accessibility sizes the value goes under its label, which would leave it no room.
    private func timeRow(_ label: String, _ value: String) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        return layout {
            Text(label)
                .foregroundStyle(Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .font(TigerDuckTheme.Typography.body)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func submission(_ feed: MoodleFeed<MoodleAssignmentSubmission>) -> some View {
        if let submission = feed.value {
            let refs = Int(assignment.assignmentId).map { id in
                submission.files.map { MoodleFileRef(file: $0, owner: .submission(id)) }
            } ?? []
            if !refs.isEmpty || submission.onlineText != nil || Self.showsNotSubmitted(submission) {
                section(String(localized: "assignment_detail_submission")) {
                    if !refs.isEmpty { fileCard(refs) }
                    if let text = submission.onlineText { markdown(MoodleHTMLText.markdown(fromHTML: text)) }
                    if Self.showsNotSubmitted(submission) {
                        Text(String(localized: "assignment_detail_not_submitted"))
                            .font(TigerDuckTheme.Typography.body)
                            .foregroundStyle(Color.textSecondary)
                    }
                }
            }
        } else {
            section(String(localized: "assignment_detail_submission")) {
                MoodleFirstLoadView(
                    failure: feed.isRefreshing ? nil : feed.failure,
                    retry: { await store.assignments.refreshSubmission(of: assignment) }
                )
            }
        }
    }

    private func commentList(_ comments: [MoodleSubmissionComment]) -> some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.lg) {
            ForEach(comments) { comment in
                VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
                    Text([MoodlePersonName.displayName(comment.authorName), comment.created.absoluteTimeString]
                        .filter { !$0.isEmpty }
                        .joined(separator: " · "))
                        .font(TigerDuckTheme.Typography.caption)
                        .monospacedDigit()
                        .foregroundStyle(Color.textSecondary)
                    markdown(MoodleHTMLText.markdown(fromHTML: comment.content))
                }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.md) {
            Text(title)
                .font(TigerDuckTheme.Typography.headline)
                .foregroundStyle(Color.textPrimary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(.top, TigerDuckTheme.Spacing.sm)
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

    private func fileCard(_ refs: [MoodleFileRef]) -> some View {
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
        .presetCard(policy: policy)
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
        guard let url = assignment.moodleOpenURL else { return }
        let web = assignment.moodleWebURL
        Task { await openURL(url, fallback: web) }
    }
}

/// An assignment's page opened outside a course detail, with the store of its course.
struct MoodleAssignmentPage: Hashable {
    let assignment: SDAssignment
    let store: MoodleCourseStore

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.assignment == rhs.assignment && lhs.store === rhs.store
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(assignment)
        hasher.combine(ObjectIdentifier(store))
    }
}
#endif
