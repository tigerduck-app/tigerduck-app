#if os(iOS)
import SwiftUI

/// The assignment's submission: its state against the due date, the files and text handed in,
/// and the comments on it.
struct MoodleAssignmentSubmissionSection: View {
    let store: MoodleCourseStore
    let record: MoodleAssignmentRecord
    let feed: MoodleFeed<MoodleAssignmentSubmission>
    let badge: MoodleAssignmentDetails.Badge?
    let policy: VisualStylePolicy
    let accent: Color
    let files: MoodleFileOpener
    let openOnMoodle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.md) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: TigerDuckTheme.Spacing.md) {
                    MoodleAssignmentSectionTitle(title: String(localized: "assignment_detail_submission"))
                    Spacer(minLength: 0)
                    if let badge { badgeView(badge) }
                }
                VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
                    MoodleAssignmentSectionTitle(title: String(localized: "assignment_detail_submission"))
                    if let badge { badgeView(badge) }
                }
            }
            if let submission = feed.value {
                if MoodleAssignmentDetails.showsCard(submission) { submissionCard(submission) }
                if let comments = submission.comments, !comments.isEmpty { commentList(comments) }
            } else {
                MoodleFirstLoadView(
                    failure: feed.isRefreshing ? nil : feed.failure,
                    retry: { await store.assignments.refreshSubmission(of: record) }
                )
            }
        }
    }


    private func badgeView(_ badge: MoodleAssignmentDetails.Badge) -> some View {
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
        .background(badge.fill, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private func submissionCard(_ submission: MoodleAssignmentSubmission) -> some View {
        let refs = submission.files.map { MoodleFileRef(file: $0, owner: .submission(record.assignId)) }
        let text = submission.onlineText
        return VStack(alignment: .leading, spacing: 0) {
            MoodleAssignmentTimeRow(
                label: submission.isSubmitted
                    ? String(localized: "assignment_detail_submitted_at")
                    : String(localized: "assignment_detail_draft"),
                time: submission.modified.map { MoodleAssignmentDetails.timeText($0) }
            )
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .padding(.top, TigerDuckTheme.Spacing.md)
            .padding(.bottom, refs.isEmpty && text == nil ? TigerDuckTheme.Spacing.md : 0)
            MoodleAssignmentFileRows(refs: refs, store: store, files: files, openOnMoodle: openOnMoodle)
            if let text {
                if !refs.isEmpty {
                    Divider().padding(.leading, MoodleFileRow.textInset)
                }
                MoodleAssignmentMarkdown(text: MoodleAssignmentDetails.markdown(ofHTML: text), accent: accent, files: files)
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
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(comments.enumerated()), id: \.element.id) { index, comment in
                    if index > 0 {
                        Divider().padding(.leading, TigerDuckTheme.Spacing.lg)
                    }
                    VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
                        Text([MoodlePersonName.displayName(comment.authorName), MoodleAssignmentDetails.timeText(comment.created)]
                            .filter { !$0.isEmpty }
                            .joined(separator: " · "))
                            .font(TigerDuckTheme.Typography.caption)
                            .monospacedDigit()
                            .foregroundStyle(Color.textSecondary)
                        MoodleAssignmentMarkdown(
                            text: MoodleAssignmentDetails.markdown(ofHTML: comment.content), accent: accent, files: files
                        )
                    }
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                    .padding(.vertical, TigerDuckTheme.Spacing.md)
                }
            }
            .presetCard(policy: policy)
        }
        .padding(.top, TigerDuckTheme.Spacing.xs)
    }
}
#endif
