import SwiftUI

struct UpcomingAssignmentsView: View {
    private static let listChangeAnimation = Animation.snappy(duration: 0.28, extraBounce: 0)

    let assignments: [SDAssignment]
    var courses: [SDCourse] = []
    var filter: AssignmentFilter = .incomplete
    var showAbsoluteTime: Bool = false
    var onArchive: ((SDAssignment) -> Void)? = nil
    var onMarkComplete: ((SDAssignment) -> Void)? = nil
    var onUnarchive: ((SDAssignment) -> Void)? = nil
    var onUndoComplete: ((SDAssignment) -> Void)? = nil
    var onOpen: (SDAssignment) -> Void = { _ in }

    @Environment(AppState.self) private var appState

    private var courseByNo: [String: SDCourse] {
        Dictionary(courses.map { ($0.courseNo, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            assignmentList(for: AppClock.now())
        }
    }

    private func assignmentList(for now: Date) -> some View {
        let policy = appState.visualStylePolicy
        let rows = filter == .all
            ? assignments.partitionedByDueDate(now: now)
            : assignments
        return Group {
            switch policy.assignmentRowStyle {
            case .card:
                cardLayout(rows: rows, policy: policy, now: now)
            case .groupedList:
                groupedListLayout(rows: rows, policy: policy, now: now)
            }
        }
    }

    private func cardLayout(rows: [SDAssignment], policy: VisualStylePolicy, now: Date) -> some View {
        LazyVStack(spacing: TigerDuckTheme.Spacing.sm) {
            ForEach(rows, id: \.assignmentId) { assignment in
                swipeableRow(assignment: assignment, now: now) {
                    assignmentRow(assignment: assignment, now: now, policy: policy)
                        .cardPadding()
                        .glassCard()
                }
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            }
        }
        .animation(Self.listChangeAnimation, value: rows.map(\.assignmentId))
    }

    private func groupedListLayout(rows: [SDAssignment], policy: VisualStylePolicy, now: Date) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.assignmentId) { index, assignment in
                swipeableRow(assignment: assignment, now: now) {
                    assignmentRow(assignment: assignment, now: now, policy: policy)
                        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                        .padding(.vertical, TigerDuckTheme.Spacing.md)
                }

                if index < rows.count - 1 {
                    Divider()
                        .padding(.leading, TigerDuckTheme.Spacing.lg)
                }
            }
        }
        .presetGroupedListContainer(policy: policy)
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .animation(Self.listChangeAnimation, value: rows.map(\.assignmentId))
    }

    private func swipeableRow<Content: View>(
        assignment: SDAssignment,
        now: Date,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let actions = rowSwipeActions(for: assignment, now: now)
        return SwipeableRow(
            leadingAction: actions.leading,
            trailingAction: actions.trailing,
            onTap: { onOpen(assignment) },
            content: content
        )
    }

    func rowSwipeActions(
        for assignment: SDAssignment,
        now: Date
    ) -> (trailing: SwipeActionDescriptor?, leading: SwipeActionDescriptor?) {
        guard !assignment.isIgnoredByCourse else { return (nil, nil) }
        let status = assignment.status(now: now)
        let gray = Color(.systemGray)

        let trailing: SwipeActionDescriptor?
        switch status {
        case .archived:
            trailing = SwipeActionDescriptor(label: String(localized: "assignment_ignore_undo"), systemImage: "arrow.uturn.backward", tint: gray) { onUnarchive?(assignment) }
        default:
            if assignment.isArchived {
                trailing = SwipeActionDescriptor(label: String(localized: "assignment_ignore_undo"), systemImage: "arrow.uturn.backward", tint: gray) { onUnarchive?(assignment) }
            } else {
                trailing = SwipeActionDescriptor(label: String(localized: "assignment_ignore"), systemImage: "archivebox.fill", tint: gray) { onArchive?(assignment) }
            }
        }

        let leading: SwipeActionDescriptor?
        switch status {
        case .locallyCompleted:
            leading = SwipeActionDescriptor(label: String(localized: "assignment_mark_complete_undo"), systemImage: "arrow.uturn.backward", tint: gray) { onUndoComplete?(assignment) }
        default:
            if assignment.isLocallyCompleted {
                leading = SwipeActionDescriptor(label: String(localized: "assignment_mark_complete_undo"), systemImage: "arrow.uturn.backward", tint: gray) { onUndoComplete?(assignment) }
            } else {
                leading = SwipeActionDescriptor(label: String(localized: "assignment_mark_complete"), systemImage: "checkmark.circle.fill", tint: .green) { onMarkComplete?(assignment) }
            }
        }

        return (trailing, leading)
    }

    @ViewBuilder
    private func assignmentRow(assignment: SDAssignment, now: Date, policy: VisualStylePolicy) -> some View {
        let status = assignment.status(now: now)
        HStack(spacing: TigerDuckTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(assignment.displayTitle)
                    .font(TigerDuckTheme.Typography.body)
                    .foregroundStyle(policy.primaryTextColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(courseLineLabel(for: assignment))
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(policy.secondaryTextColor)
                    .lineLimit(1)
            }
            Spacer(minLength: TigerDuckTheme.Spacing.xs)
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

    private func courseLineLabel(for assignment: SDAssignment) -> String {
        assignment.courseLineLabel(matching: courseByNo[assignment.courseNo])
    }

    @ViewBuilder
    private func trailingStatus(
        assignment: SDAssignment,
        status: AssignmentStatus,
        now: Date,
        policy: VisualStylePolicy
    ) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let extra = secondaryBadge(for: assignment, status: status, now: now) {
                Text(extra.label)
                    .font(statusFont(status: status))
                    .foregroundStyle(extra.tint)
                    .lineLimit(1)
            }
            if let label = status.badgeLabel {
                Text(label)
                    .font(statusFont(status: status))
                    .foregroundStyle(status.tint)
                    .lineLimit(1)
            }
            Text(timeLabel(for: assignment, now: now))
                .font(timeFont(status: status))
                .foregroundStyle(timeColor(status: status, policy: policy))
                .lineLimit(1)
        }
    }

    private func secondaryBadge(
        for assignment: SDAssignment,
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

    private func timeLabel(for assignment: SDAssignment, now: Date) -> String {
        if showAbsoluteTime || assignment.dueDate < now {
            return assignment.dueDate.absoluteTimeString
        }
        return assignment.dueDate.relativeTimeString(from: now)
    }
}

struct SwipeActionDescriptor {
    let label: String
    let systemImage: String
    let tint: Color
    let action: () -> Void
}

private struct SwipeableRow<Content: View>: View {
    let leadingAction: SwipeActionDescriptor?
    let trailingAction: SwipeActionDescriptor?
    let onTap: () -> Void
    let content: Content

    @State private var offset: CGFloat = 0
    @State private var didSwipe = false

    private let triggerThreshold: CGFloat = 96
    private let snapAnimation = Animation.spring(response: 0.32, dampingFraction: 0.78)

    init(
        leadingAction: SwipeActionDescriptor?,
        trailingAction: SwipeActionDescriptor?,
        onTap: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.leadingAction = leadingAction
        self.trailingAction = trailingAction
        self.onTap = onTap
        self.content = content()
    }

    var body: some View {
        ZStack {
            actionBackdrop
            tappableContent
        }
    }

    @ViewBuilder
    private var tappableContent: some View {
        Button {
            guard !didSwipe else { return }
            onTap()
        } label: {
            content
        }
        .buttonStyle(SwipeableButtonStyle(didSwipe: $didSwipe))
        .contentShape(Rectangle())
        .offset(x: offset)
        .simultaneousGesture(dragGesture)
        .accessibilityActions {
            if let leadingAction {
                Button(leadingAction.label, action: leadingAction.action)
            }
            if let trailingAction {
                Button(trailingAction.label, action: trailingAction.action)
            }
        }
    }

    @ViewBuilder
    private var actionBackdrop: some View {
        HStack(spacing: 0) {
            if let leadingAction, offset > 0 {
                actionSlab(leadingAction)
                    .frame(width: max(0, offset))
            }
            Spacer(minLength: 0)
            if let trailingAction, offset < 0 {
                actionSlab(trailingAction)
                    .frame(width: max(0, -offset))
            }
        }
    }

    private func actionSlab(_ action: SwipeActionDescriptor) -> some View {
        let progress = min(1, max(0, abs(offset) / triggerThreshold))
        return ZStack {
            action.tint
            Image(systemName: action.systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .opacity(progress)
                .scaleEffect(0.6 + 0.4 * progress)
        }
        .clipShape(RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md))
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                didSwipe = true
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.3 else { return }
                if dx > 0 && leadingAction == nil { return }
                if dx < 0 && trailingAction == nil { return }
                offset = dx
            }
            .onEnded { _ in
                let triggered = abs(offset) > triggerThreshold
                if triggered, let action = (offset > 0 ? leadingAction : trailingAction) {
                    action.action()
                }
                snapBack()
            }
    }

    private func snapBack() {
        withAnimation(snapAnimation) {
            offset = 0
        }
    }
}

private struct SwipeableButtonStyle: ButtonStyle {
    @Binding var didSwipe: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed { didSwipe = false }
            }
    }
}
