#if os(iOS)
import SwiftUI
import TigerDuckCore

struct MoodleAssignmentView: View {
    let store: MoodleCourseStore
    let entry: MoodleCourseAssignments.Entry
    let courseName: String
    let policy: VisualStylePolicy
    let accent: Color
    var noteSleep: @Sendable (Duration) async -> Void = { try? await AppClock.sleep(until: ContinuousClock.now + $0) }

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var openedId: Int?
    @State private var files = MoodleFileOpener()

    private var record: MoodleAssignmentRecord { entry.record }

    var body: some View {
        let feed = store.assignments.submission(of: record)
        let submission = feed.value
        let isSubmitted = MoodleAssignmentDetails.isSubmitted(record: record, listed: entry.listed, submission: submission)
        let due = MoodleAssignmentDetails.due(of: entry, submission: submission)
        let description = MoodleAssignmentDetails.markdown(ofHTML: record.intro)
        ScrollView {
            VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xl) {
                header
                MoodleAssignmentSummaryCard(
                    due: due, isSubmitted: isSubmitted, group: submission?.groupName, policy: policy, accent: accent
                )
                if !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    section(String(localized: "assignment_detail_description")) {
                        MoodleAssignmentMarkdown(text: description, accent: accent, files: files)
                    }
                }
                if !record.introAttachments.isEmpty {
                    section(String(localized: "school_mail_attachments")) {
                        MoodleAssignmentFileRows(
                            refs: record.introAttachments.map { MoodleFileRef(file: $0, owner: .module(record.cmId)) },
                            store: store, files: files, openOnMoodle: openOnMoodle
                        )
                        .presetCard(policy: policy)
                    }
                }
                if !record.noSubmissions {
                    Divider().background(Color.textSecondary)
                    MoodleAssignmentSubmissionSection(
                        store: store, record: record, feed: feed,
                        badge: MoodleAssignmentDetails.badge(
                            isSubmitted: isSubmitted,
                            submittedAt: MoodleAssignmentDetails.submittedAt(of: entry.listed, submission: submission),
                            due: due
                        ),
                        policy: policy, accent: accent, files: files, openOnMoodle: openOnMoodle
                    )
                }
                if let grade = submission?.grade {
                    MoodleAssignmentGradeSection(grade: grade, policy: policy, accent: accent, files: files)
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
        .moodleRefreshFailureNote(feed, hasContent: submission != nil, sleep: noteSleep)
        .moodleArticleChrome()
        .task(id: record.assignId) {
            guard openedId != record.assignId else { return }
            openedId = record.assignId
            await store.assignments.refreshSubmission(of: record)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await store.assignments.refreshSubmission(of: record) }
        }
        .moodleFilePresentation(files)
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

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.md) {
            MoodleAssignmentSectionTitle(title: title)
            content()
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

    private func openOnMoodle() {
        files.forgetPendingOpen()
        Task { await openURL(MoodlePage.module("assign", cmid: record.cmId)) }
    }
}

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
