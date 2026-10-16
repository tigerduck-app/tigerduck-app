import SwiftUI

/// A course's assignments as the last assignment round left them: those still to come by due
/// time, then the past ones, the latest first, each with what Moodle says of it on the right.
struct MoodleAssignmentsView: View {
    let store: MoodleCourseStore
    let policy: VisualStylePolicy
    let refresh: () async -> Void
    let open: (SDAssignment) -> Void

    struct Row: Identifiable {
        let assignment: SDAssignment
        let status: AssignmentStatus?

        var id: String { assignment.assignmentId }
    }

    var body: some View {
        // `TimelineView` runs on wall time; the rows read `AppClock`, so the debug clock applies.
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            ScrollView {
                card(Self.rows(of: store.assignments.list, now: AppClock.now()))
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                    .padding(.vertical, TigerDuckTheme.Spacing.xs)
            }
        }
        .background(Color.backgroundPrimary)
        .refreshable { await refresh() }
        .moodleListChrome(
            title: String(localized: "course_detail_assignments_label"),
            page: .assignments(courseId: store.courseId),
            refresh: refresh
        )
    }

    static func rows(of assignments: [SDAssignment], now: Date) -> [Row] {
        assignments.partitionedByDueDate(now: now).map { Row(assignment: $0, status: shownStatus(of: $0, now: now)) }
    }

    /// What Moodle says of the assignment, without the marks the user puts on Home's rows: handed
    /// in on time or late, or overdue, and nothing while it is still to come.
    static func shownStatus(of assignment: SDAssignment, now: Date) -> AssignmentStatus? {
        switch assignment.moodleStatus(now: now) {
        case .submitted: .submitted
        case .submittedLate: .submittedLate
        case .overdueAcceptable, .overdueRejected: .overdueAcceptable
        case .pending, .archived, .locallyCompleted: nil
        }
    }

    private func card(_ rows: [Row]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Divider().padding(.leading, TigerDuckTheme.Spacing.lg)
                }
                Button {
                    open(row.assignment)
                } label: {
                    MoodleAssignmentRow(row: row)
                }
                .buttonStyle(.plain)
                .moodleRowHover()
            }
        }
        .presetCard(policy: policy)
    }
}

private struct MoodleAssignmentRow: View {
    let row: MoodleAssignmentsView.Row

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At accessibility sizes the time beside the title would leave the title no room.
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs))
            : AnyLayout(HStackLayout(spacing: TigerDuckTheme.Spacing.md))
        HStack(spacing: TigerDuckTheme.Spacing.md) {
            layout {
                Text(row.assignment.displayTitle)
                    .font(TigerDuckTheme.Typography.body)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(stacked ? nil : 2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: stacked ? .leading : .trailing, spacing: 2) {
                    if let status = row.status, let label = status.badgeLabel {
                        Text(label)
                            .font(TigerDuckTheme.Typography.caption.weight(.semibold))
                            .foregroundStyle(status.tint)
                    }
                    Text(row.assignment.dueDate.absoluteTimeString)
                        .font(TigerDuckTheme.Typography.caption)
                        .monospacedDigit()
                        .foregroundStyle(Color.textSecondary)
                }
                .fixedSize()
            }
            Image(systemName: Self.accessory)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.textSecondary.opacity(0.5))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.vertical, TigerDuckTheme.Spacing.md)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// The Mac opens the assignment on Moodle, as it has no page of its own for it.
    #if os(macOS)
    private static let accessory = "arrow.up.right.square"
    #else
    private static let accessory = "chevron.right"
    #endif
}
