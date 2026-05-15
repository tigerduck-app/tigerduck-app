import SwiftUI

struct UpcomingAssignmentsView: View {
    private static let listChangeAnimation = Animation.snappy(duration: 0.28, extraBounce: 0)

    let assignments: [SDAssignment]
    var showAbsoluteTime: Bool = false
    var onArchive: ((SDAssignment) -> Void)? = nil
    var onMarkComplete: ((SDAssignment) -> Void)? = nil
    var onUnarchive: ((SDAssignment) -> Void)? = nil
    var onUndoComplete: ((SDAssignment) -> Void)? = nil

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
        List {
            ForEach(assignments, id: \.assignmentId) { assignment in
                swipeableCardRow(assignment: assignment, now: now, policy: policy)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(
                        EdgeInsets(
                            top: 0,
                            leading: TigerDuckTheme.Spacing.lg,
                            bottom: TigerDuckTheme.Spacing.sm,
                            trailing: TigerDuckTheme.Spacing.lg
                        )
                    )
            }
        }
        .listStyle(.plain)
        .scrollDisabled(true)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .frame(height: listHeight(for: policy))
        .animation(Self.listChangeAnimation, value: assignments.map(\.assignmentId))
    }

    private func groupedListLayout(policy: VisualStylePolicy, now: Date) -> some View {
        List {
            ForEach(Array(assignments.enumerated()), id: \.element.assignmentId) { index, assignment in
                swipeableListRow(assignment: assignment, now: now, policy: policy)
                    .overlay(alignment: .bottom) {
                        if index < assignments.count - 1 {
                            Divider()
                                .padding(.leading, TigerDuckTheme.Spacing.lg)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
        }
        .listStyle(.plain)
        .scrollDisabled(true)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .frame(height: listHeight(for: policy))
        .presetGroupedListContainer(policy: policy)
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .animation(Self.listChangeAnimation, value: assignments.map(\.assignmentId))
    }

    private func listHeight(for policy: VisualStylePolicy) -> CGFloat {
        guard !assignments.isEmpty else { return 0 }
        let count = CGFloat(assignments.count)
        switch policy.assignmentRowStyle {
        case .card:
            let rowHeight: CGFloat = 82
            let spacing: CGFloat = TigerDuckTheme.Spacing.sm
            return count * rowHeight + max(0, count - 1) * spacing
        case .groupedList:
            let rowHeight: CGFloat = 56
            let separators = max(0, count - 1)
            return count * rowHeight + separators
        }
    }

    private func swipeableCardRow(
        assignment: SDAssignment,
        now: Date,
        policy: VisualStylePolicy
    ) -> some View {
        let actions = rowSwipeActions(for: assignment, now: now)
        return AssignmentSwipeRow(
            trailingAction: actions.trailing,
            leadingAction: actions.leading,
            onTap: { openAssignment(assignment) }
        ) {
            assignmentRow(assignment: assignment, now: now, policy: policy)
                .cardPadding()
                .glassCard()
        }
    }

    private func swipeableListRow(
        assignment: SDAssignment,
        now: Date,
        policy: VisualStylePolicy
    ) -> some View {
        let actions = rowSwipeActions(for: assignment, now: now)
        return AssignmentSwipeRow(
            trailingAction: actions.trailing,
            leadingAction: actions.leading,
            onTap: { openAssignment(assignment) }
        ) {
            assignmentRow(assignment: assignment, now: now, policy: policy)
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                .padding(.vertical, TigerDuckTheme.Spacing.md)
        }
    }

    private func rowSwipeActions(
        for assignment: SDAssignment,
        now: Date
    ) -> (trailing: SwipeActionDescriptor?, leading: SwipeActionDescriptor?) {
        let status = assignment.status(now: now)
        let gray = Color(.systemGray)

        let trailing: SwipeActionDescriptor?
        switch status {
        case .pending, .overdueAcceptable, .overdueRejected:
            trailing = SwipeActionDescriptor(label: String(localized: "assignment_ignore"), systemImage: "archivebox.fill", tint: gray) { onArchive?(assignment) }
        case .archived:
            trailing = SwipeActionDescriptor(label: String(localized: "assignment_ignore_undo"), systemImage: "arrow.uturn.backward", tint: gray) { onUnarchive?(assignment) }
        default:
            trailing = nil
        }

        let leading: SwipeActionDescriptor?
        switch status {
        case .pending, .overdueAcceptable, .overdueRejected:
            leading = SwipeActionDescriptor(label: String(localized: "assignment_mark_complete"), systemImage: "checkmark.circle.fill", tint: .green) { onMarkComplete?(assignment) }
        case .locallyCompleted:
            leading = SwipeActionDescriptor(label: String(localized: "assignment_mark_complete_undo"), systemImage: "arrow.uturn.backward", tint: gray) { onUndoComplete?(assignment) }
        default:
            leading = nil
        }

        return (trailing, leading)
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
                Text(assignment.displayCourseName)
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
        case .archived, .locallyCompleted:
            // Time label stays red — Moodle still considers these unsubmitted overdue items.
            return .badgeRed
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

// MARK: - Swipe gesture helpers

private struct SwipeActionDescriptor {
    let label: String
    let systemImage: String
    let tint: Color
    let action: () -> Void
}

private struct AssignmentSwipeRow<Content: View>: View {
    let content: Content
    let trailingAction: SwipeActionDescriptor?
    let leadingAction: SwipeActionDescriptor?
    let onTap: () -> Void

    init(
        trailingAction: SwipeActionDescriptor?,
        leadingAction: SwipeActionDescriptor?,
        onTap: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.trailingAction = trailingAction
        self.leadingAction = leadingAction
        self.onTap = onTap
        self.content = content()
    }

    var body: some View {
        Button(action: onTap) {
            content
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if let trailingAction {
                swipeButton(for: trailingAction)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if let leadingAction {
                swipeButton(for: leadingAction)
            }
        }
    }

    @ViewBuilder
    private func swipeButton(for action: SwipeActionDescriptor) -> some View {
        Button(action: action.action) {
            Label(action.label, systemImage: action.systemImage)
                .labelStyle(.iconOnly)
        }
        .tint(action.tint)
    }
}
