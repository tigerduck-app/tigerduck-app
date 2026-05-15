import SwiftUI

struct UpcomingAssignmentsView: View {
    private static let listChangeAnimation = Animation.snappy(duration: 0.28, extraBounce: 0)

    let assignments: [SDAssignment]
    var filter: AssignmentFilter = .incomplete
    var showAbsoluteTime: Bool = false
    var onArchive: ((SDAssignment) -> Void)? = nil
    var onMarkComplete: ((SDAssignment) -> Void)? = nil
    var onUnarchive: ((SDAssignment) -> Void)? = nil
    var onUndoComplete: ((SDAssignment) -> Void)? = nil

    @Environment(AppState.self) private var appState

    /// Per-row content height reported back via `RowHeightPreferenceKey`.
    /// Title wrapping makes the row genuinely variable-height, so the parent
    /// ScrollView's section height must follow what was actually laid out
    /// rather than a guessed constant — otherwise either the last row clips
    /// or the section reserves a black gap beneath the list.
    @State private var rowHeights: [String: CGFloat] = [:]

    /// Conservative fallback used on the first render before the
    /// PreferenceKey reports back. Sized for a 3-line worst case so the
    /// initial layout doesn't clip; once measured, the real value takes
    /// over.
    @ScaledMetric(relativeTo: .body) private var fallbackRowHeight: CGFloat = 96

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
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                    .padding(.vertical, TigerDuckTheme.Spacing.sm / 2)
                    .background(rowHeightReporter(for: assignment))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
        }
        .listStyle(.plain)
        .scrollDisabled(true)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .frame(height: totalListHeight(for: policy))
        .onPreferenceChange(RowHeightPreferenceKey.self) { newHeights in
            rowHeights = newHeights
        }
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
                    .background(rowHeightReporter(for: assignment))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
        }
        .listStyle(.plain)
        .scrollDisabled(true)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .frame(height: totalListHeight(for: policy))
        .presetGroupedListContainer(policy: policy)
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .onPreferenceChange(RowHeightPreferenceKey.self) { newHeights in
            rowHeights = newHeights
        }
        .animation(Self.listChangeAnimation, value: assignments.map(\.assignmentId))
    }

    /// Sums the measured row heights so the List frame matches what's
    /// actually rendered. While measurements are pending (first frame,
    /// row insertions), each unknown row falls back to a 3-line estimate.
    private func totalListHeight(for policy: VisualStylePolicy) -> CGFloat {
        guard !assignments.isEmpty else { return 0 }
        return assignments.reduce(0) { sum, assignment in
            sum + (rowHeights[assignment.assignmentId] ?? fallbackRowHeight)
        }
    }

    /// Background helper that reports the measured row size up through a
    /// `PreferenceKey`. Used for both card and grouped-list layouts so the
    /// `totalListHeight` math is single-sourced.
    private func rowHeightReporter(for assignment: SDAssignment) -> some View {
        GeometryReader { proxy in
            Color.clear
                .preference(
                    key: RowHeightPreferenceKey.self,
                    value: [assignment.assignmentId: proxy.size.height]
                )
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
        HStack(alignment: .top, spacing: TigerDuckTheme.Spacing.md) {
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

    /// "課名 • 課程ID" — the third line beneath the (possibly wrapped) title.
    /// The course code is dropped when it would just repeat the name (e.g.,
    /// an unknown course where `displayCourseName` already falls back to the
    /// courseNo).
    private func courseLineLabel(for assignment: SDAssignment) -> String {
        let name = assignment.displayCourseName
        let code = assignment.courseNo
        if code.isEmpty || name == code {
            return name
        }
        return "\(name) • \(code)"
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
                    .lineLimit(1)
            }
            Text(timeLabel(for: assignment, now: now))
                .font(timeFont(status: status))
                .foregroundStyle(timeColor(status: status, policy: policy))
                .lineLimit(1)
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

    /// Resolves the right-side time text. The 全部 tab uses time-based
    /// branching (past rows always show the absolute deadline as the
    /// second line); other tabs keep the legacy "relative unless toggled,
    /// override to absolute for completed-and-past" rule.
    private func timeLabel(for assignment: SDAssignment, now: Date) -> String {
        let isPast = assignment.dueDate < now
        if filter == .all && isPast {
            return assignment.dueDate.absoluteTimeString
        }
        if showAbsoluteTime || (assignment.isCompleted && isPast) {
            return assignment.dueDate.absoluteTimeString
        }
        return assignment.dueDate.relativeTimeString(from: now)
    }
}

// MARK: - Row height plumbing

private struct RowHeightPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
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
