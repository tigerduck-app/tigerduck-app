import SwiftUI

struct UpcomingAssignmentsView: View {
    let assignments: [SDAssignment]
    var showAbsoluteTime: Bool = false
    var onArchive: ((SDAssignment) -> Void)? = nil
    var onMarkComplete: ((SDAssignment) -> Void)? = nil

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
                let status = assignment.status(now: now)
                SwipeToActRow(
                    isEligible: status.isSwipeActionEligible,
                    onArchive: { onArchive?(assignment) },
                    onMarkComplete: { onMarkComplete?(assignment) }
                ) {
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
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    private func groupedListLayout(policy: VisualStylePolicy, now: Date) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(assignments.enumerated()), id: \.element.assignmentId) { index, assignment in
                let status = assignment.status(now: now)
                SwipeToActRow(
                    isEligible: status.isSwipeActionEligible,
                    onArchive: { onArchive?(assignment) },
                    onMarkComplete: { onMarkComplete?(assignment) }
                ) {
                    Button {
                        openAssignment(assignment)
                    } label: {
                        assignmentRow(assignment: assignment, now: now, policy: policy)
                            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                            .padding(.vertical, TigerDuckTheme.Spacing.md)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

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

// MARK: - Swipe gesture helper

private struct SwipeToActRow<Content: View>: View {
    let content: Content
    let isEligible: Bool
    let onArchive: () -> Void
    let onMarkComplete: () -> Void

    @State private var dragX: CGFloat = 0

    private let maxDrag: CGFloat = 75
    private let threshold: CGFloat = 50

    init(
        isEligible: Bool,
        onArchive: @escaping () -> Void,
        onMarkComplete: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.isEligible = isEligible
        self.onArchive = onArchive
        self.onMarkComplete = onMarkComplete
        self.content = content()
    }

    var body: some View {
        if isEligible {
            ZStack {
                actionBackground
                content.offset(x: dragX)
            }
            .clipped()
            .gesture(swipeGesture)
        } else {
            content
        }
    }

    @ViewBuilder
    private var actionBackground: some View {
        if dragX < 0 {
            HStack {
                Spacer()
                Image(systemName: "archivebox.fill")
                    .foregroundStyle(.white)
                    .font(.body.weight(.medium))
                    .padding(.trailing, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.orange)
            .opacity(Double(min(abs(dragX) / threshold, 1.0)))
        } else if dragX > 0 {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.white)
                    .font(.body.weight(.medium))
                    .padding(.leading, 20)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.blue)
            .opacity(Double(min(dragX / threshold, 1.0)))
        }
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 15)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragX = value.translation.width > 0
                    ? min(value.translation.width, maxDrag)
                    : max(value.translation.width, -maxDrag)
            }
            .onEnded { _ in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    if dragX <= -threshold { onArchive() }
                    else if dragX >= threshold { onMarkComplete() }
                    dragX = 0
                }
            }
    }
}
