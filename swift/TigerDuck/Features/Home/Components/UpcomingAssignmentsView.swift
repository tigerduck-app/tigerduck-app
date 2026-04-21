import SwiftUI

struct UpcomingAssignmentsView: View {
    let assignments: [SDAssignment]
    var showAbsoluteTime: Bool = false

    @Environment(AppState.self) private var appState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            assignmentList(for: context.date)
        }
    }

    private func assignmentList(for now: Date) -> some View {
        let policy = appState.visualStylePolicy
        return Group {
            switch policy.assignmentRowStyle {
            case .card:
                cardLayout(policy: policy, now: now)
            case .groupedList:
                groupedListLayout(policy: policy, now: now)
            }
        }
    }

    private func cardLayout(policy: VisualStylePolicy, now: Date) -> some View {
        VStack(spacing: TigerDuckTheme.Spacing.sm) {
            ForEach(assignments, id: \.assignmentId) { assignment in
                Button {
                    openAssignment(assignment)
                } label: {
                    assignmentRow(assignment: assignment, now: now, policy: policy)
                        .cardPadding()
                        .glassCard()
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    private func groupedListLayout(policy: VisualStylePolicy, now: Date) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(assignments.enumerated()), id: \.element.assignmentId) { index, assignment in
                Button {
                    openAssignment(assignment)
                } label: {
                    assignmentRow(assignment: assignment, now: now, policy: policy)
                        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                        .padding(.vertical, TigerDuckTheme.Spacing.md)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if index < assignments.count - 1 {
                    Divider()
                        .padding(.leading, TigerDuckTheme.Spacing.lg)
                }
            }
        }
        .presetGroupedListContainer(policy: policy)
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    @ViewBuilder
    private func assignmentRow(assignment: SDAssignment, now: Date, policy: VisualStylePolicy) -> some View {
        let status = assignment.status(now: now)
        HStack(spacing: TigerDuckTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(assignment.title)
                    .font(TigerDuckTheme.Typography.body)
                    .foregroundStyle(policy.primaryTextColor)
                    .lineLimit(1)
                Text(assignment.courseName)
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(policy.secondaryTextColor)
            }
            Spacer()
            trailingStatus(
                assignment: assignment,
                status: status,
                now: now,
                policy: policy
            )

            if policy.assignmentRowStyle == .groupedList {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func trailingStatus(
        assignment: SDAssignment,
        status: AssignmentStatus,
        now: Date,
        policy: VisualStylePolicy
    ) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let label = status.badgeLabel {
                Text(label)
                    .font(statusFont(status: status))
                    .foregroundStyle(status.tint)
            }
            Text(timeLabel(for: assignment, now: now))
                .font(timeFont(status: status))
                .foregroundStyle(timeColor(status: status, policy: policy))
        }
    }

    private func statusFont(status: AssignmentStatus) -> Font {
        let base = TigerDuckTheme.Typography.caption
        return status.usesEmphasis ? base.weight(.bold) : base.weight(.semibold)
    }

    private func timeFont(status: AssignmentStatus) -> Font {
        let base = TigerDuckTheme.Typography.caption
        return status.usesEmphasis ? base.weight(.bold) : base
    }

    /// Only overdue rows tint the due time red. Submitted rows keep the
    /// secondary body color so the green/orange status badge reads as the
    /// primary signal and the time is just metadata.
    private func timeColor(status: AssignmentStatus, policy: VisualStylePolicy) -> Color {
        switch status {
        case .overdueAcceptable, .overdueRejected:
            return status.tint
        case .pending, .submitted, .submittedLate:
            return policy.secondaryTextColor
        }
    }

    private func openAssignment(_ assignment: SDAssignment) {
        if let url = assignment.moodleDeepLink {
            UIApplication.shared.open(url)
        }
    }

    private func timeLabel(for assignment: SDAssignment, now: Date) -> String {
        if showAbsoluteTime || (assignment.isCompleted && assignment.dueDate < now) {
            return assignment.dueDate.absoluteTimeString
        } else {
            return assignment.dueDate.relativeTimeString(from: now)
        }
    }
}
