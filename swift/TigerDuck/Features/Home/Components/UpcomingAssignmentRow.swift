import SwiftUI

/// One row of Home's assignment list: the title and course, then the status and due time.
struct UpcomingAssignmentRow: View {
    let assignment: AssignmentStore.Assignment
    let course: CourseStore.Course?
    let now: Date
    let policy: VisualStylePolicy
    let showAbsoluteTime: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let status = assignment.status(now: now)
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs))
            : AnyLayout(HStackLayout(spacing: TigerDuckTheme.Spacing.md))
        HStack(spacing: TigerDuckTheme.Spacing.md) {
            layout {
                VStack(alignment: .leading, spacing: 2) {
                    Text(assignment.displayTitle)
                        .font(TigerDuckTheme.Typography.body)
                        .foregroundStyle(policy.primaryTextColor)
                        .lineLimit(stacked ? nil : 2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(courseLineLabel(for: assignment))
                        .font(TigerDuckTheme.Typography.caption)
                        .foregroundStyle(policy.secondaryTextColor)
                        .lineLimit(stacked ? nil : 1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: stacked ? .infinity : nil, alignment: .leading)
                if !stacked {
                    Spacer(minLength: TigerDuckTheme.Spacing.xs)
                }
                trailingStatus(
                    assignment: assignment,
                    status: status,
                    now: now,
                    policy: policy,
                    stacked: stacked
                )
            }

            if policy.assignmentRowStyle == .groupedList {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func courseLineLabel(for assignment: AssignmentStore.Assignment) -> String {
        assignment.courseLineLabel(matching: course)
    }

    @ViewBuilder
    private func trailingStatus(
        assignment: AssignmentStore.Assignment,
        status: AssignmentStatus,
        now: Date,
        policy: VisualStylePolicy,
        stacked: Bool
    ) -> some View {
        let lineLimit = stacked ? nil : 1
        VStack(alignment: stacked ? .leading : .trailing, spacing: 2) {
            if let extra = secondaryBadge(for: assignment, status: status, now: now) {
                Text(extra.label)
                    .font(statusFont(status: status))
                    .foregroundStyle(extra.tint)
                    .lineLimit(lineLimit)
            }
            if let label = status.badgeLabel {
                Text(label)
                    .font(statusFont(status: status))
                    .foregroundStyle(status.tint)
                    .lineLimit(lineLimit)
            }
            Text(timeLabel(for: assignment, now: now))
                .font(timeFont(status: status))
                .foregroundStyle(timeColor(status: status, policy: policy))
                .lineLimit(lineLimit)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func secondaryBadge(
        for assignment: AssignmentStore.Assignment,
        status: AssignmentStatus,
        now: Date
    ) -> (label: String, tint: Color)? {
        if (status == .submitted || status == .submittedLate) && assignment.isLocallyCompleted {
            return (AssignmentStatus.locallyCompleted.badgeLabel!, AssignmentStatus.locallyCompleted.tint)
        }
        if (status == .submitted || status == .submittedLate) && assignment.isArchived {
            return (AssignmentStatus.archived.badgeLabel!, AssignmentStatus.archived.tint)
        }
        if status == .locallyCompleted || status == .archived {
            guard assignment.dueDate < now else { return nil }
            if let cutoff = assignment.cutoffDate, now > cutoff {
                return (AssignmentStatus.overdueRejected.badgeLabel!, AssignmentStatus.overdueRejected.tint)
            }
            return (AssignmentStatus.overdueAcceptable.badgeLabel!, AssignmentStatus.overdueAcceptable.tint)
        }
        return nil
    }

    private func statusFont(status: AssignmentStatus) -> Font {
        let base = TigerDuckTheme.Typography.caption
        return status.usesEmphasis ? base.weight(.bold) : base.weight(.semibold)
    }

    private func timeFont(status: AssignmentStatus) -> Font {
        let base = TigerDuckTheme.Typography.caption
        return status.usesEmphasis ? base.weight(.bold) : base
    }

    private func timeColor(status: AssignmentStatus, policy: VisualStylePolicy) -> Color {
        switch status {
        case .overdueAcceptable, .overdueRejected:
            return status.tint
        case .archived, .locallyCompleted:
            return .badgeRed
        case .pending, .submitted, .submittedLate:
            return policy.secondaryTextColor
        }
    }

    private func timeLabel(for assignment: AssignmentStore.Assignment, now: Date) -> String {
        if showAbsoluteTime || assignment.dueDate < now {
            return assignment.dueDate.absoluteTimeString
        }
        return assignment.dueDate.relativeTimeString(from: now)
    }
}
