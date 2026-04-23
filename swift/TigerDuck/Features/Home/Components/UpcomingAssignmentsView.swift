import SwiftUI

struct UpcomingAssignmentsView: View {
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
        VStack(spacing: TigerDuckTheme.Spacing.sm) {
            ForEach(assignments, id: \.assignmentId) { assignment in
                swipeableCardRow(assignment: assignment, now: now, policy: policy)
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    private func groupedListLayout(policy: VisualStylePolicy, now: Date) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(assignments.enumerated()), id: \.element.assignmentId) { index, assignment in
                swipeableListRow(assignment: assignment, now: now, policy: policy)
                if index < assignments.count - 1 {
                    Divider()
                        .padding(.leading, TigerDuckTheme.Spacing.lg)
                }
            }
        }
        .presetGroupedListContainer(policy: policy)
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    private func swipeableCardRow(
        assignment: SDAssignment,
        now: Date,
        policy: VisualStylePolicy
    ) -> some View {
        let actions = rowSwipeActions(for: assignment, now: now)
        return SwipeToActRow(
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
        return SwipeToActRow(
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
        case .overdueAcceptable, .overdueRejected:
            trailing = SwipeActionDescriptor(label: "封存", systemImage: "archivebox.fill", tint: gray) { onArchive?(assignment) }
        case .archived:
            trailing = SwipeActionDescriptor(label: "取消封存", systemImage: "arrow.uturn.backward", tint: gray) { onUnarchive?(assignment) }
        default:
            trailing = nil
        }

        let leading: SwipeActionDescriptor?
        switch status {
        case .overdueAcceptable, .overdueRejected:
            leading = SwipeActionDescriptor(label: "標示為完成", systemImage: "checkmark.circle.fill", tint: .green) { onMarkComplete?(assignment) }
        case .locallyCompleted:
            leading = SwipeActionDescriptor(label: "取消完成", systemImage: "arrow.uturn.backward", tint: gray) { onUndoComplete?(assignment) }
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

// MARK: - Swipe gesture helpers

private struct SwipeActionDescriptor {
    let label: String
    let systemImage: String
    let tint: Color
    let action: () -> Void
}

private struct SwipeToActRow<Content: View>: View {
    let content: Content
    let trailingAction: SwipeActionDescriptor?  // revealed on left swipe
    let leadingAction: SwipeActionDescriptor?   // revealed on right swipe
    let onTap: (() -> Void)?

    @State private var dragX: CGFloat = 0
    /// Locked to true once the gesture is confirmed horizontal, preventing
    /// accumulated vertical drift from freezing dragX mid-reversal.
    @State private var gestureIsHorizontal = false

    private let threshold: CGFloat = 72

    init(
        trailingAction: SwipeActionDescriptor?,
        leadingAction: SwipeActionDescriptor?,
        onTap: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.trailingAction = trailingAction
        self.leadingAction = leadingAction
        self.onTap = onTap
        self.content = content()
    }

    private var hasAnyAction: Bool { trailingAction != nil || leadingAction != nil }

    var body: some View {
        ZStack {
            if hasAnyAction { actionBackground }
            content.offset(x: dragX)
        }
        .contentShape(Rectangle())
        .clipped()
        // Tap and drag are exclusive: when DragGesture recognises (>15 pt),
        // SwiftUI cancels the TapGesture automatically, so the tap action never
        // fires after a real swipe. No Button inside means no separate tap
        // recogniser that can escape this cancellation.
        .onTapGesture { onTap?() }
        .gesture(hasAnyAction ? swipeGesture : nil)
    }

    @ViewBuilder
    private var actionBackground: some View {
        if dragX < 0, let action = trailingAction {
            action.tint
                .overlay(alignment: .trailing) {
                    VStack(spacing: 6) {
                        Image(systemName: action.systemImage).font(.title3)
                        Text(action.label).font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.trailing, 20)
                }
        } else if dragX > 0, let action = leadingAction {
            action.tint
                .overlay(alignment: .leading) {
                    VStack(spacing: 6) {
                        Image(systemName: action.systemImage).font(.title3)
                        Text(action.label).font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.leading, 20)
                }
        }
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 15)
            .onChanged { value in
                // Lock gesture direction on first clearly horizontal movement.
                // Using cumulative translation for the check means we only lock
                // once — after that, all movements in this gesture update dragX
                // regardless of the current width/height ratio, so reversing
                // direction mid-swipe stays smooth.
                if !gestureIsHorizontal {
                    let w = abs(value.translation.width)
                    let h = abs(value.translation.height)
                    guard w > h else { return }
                    gestureIsHorizontal = true
                }
                isGesturing = true
                let raw = value.translation.width
                // Allow return toward center (dragX != 0) even if that direction
                // has no action, so the row can snap back smoothly.
                guard (raw < 0 && trailingAction != nil)
                        || (raw > 0 && leadingAction != nil)
                        || dragX != 0 else { return }
                if abs(raw) > threshold {
                    let excess = abs(raw) - threshold
                    dragX = raw > 0 ? threshold + excess * 0.3 : -(threshold + excess * 0.3)
                } else {
                    dragX = raw
                }
            }
            .onEnded { _ in
                gestureIsHorizontal = false
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    if dragX <= -threshold { trailingAction?.action() }
                    else if dragX >= threshold { leadingAction?.action() }
                    dragX = 0
                }
            }
    }
}
