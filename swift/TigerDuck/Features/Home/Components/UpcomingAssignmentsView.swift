import SwiftUI

struct UpcomingAssignmentsView: View {
    private static let listChangeAnimation = Animation.snappy(duration: 0.28, extraBounce: 0)

    let assignments: [SDAssignment]
    /// In-memory course roster that resolves the canonical display name and
    /// course code for the row's third line. Without it the row falls back to
    /// `assignment.courseName` (the Moodle fullname with the code stripped,
    /// fragile) and `assignment.courseNo` (empty when Moodle's `idnumber` lacks
    /// the semester prefix), so the "course name • course ID" line can look
    /// wrong or lose the ID.
    var courses: [SDCourse] = []
    var filter: AssignmentFilter = .incomplete
    var showAbsoluteTime: Bool = false
    var onArchive: ((SDAssignment) -> Void)? = nil
    var onMarkComplete: ((SDAssignment) -> Void)? = nil
    var onUnarchive: ((SDAssignment) -> Void)? = nil
    var onUndoComplete: ((SDAssignment) -> Void)? = nil

    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL

    private var courseByNo: [String: SDCourse] {
        Dictionary(courses.map { ($0.courseNo, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        // TimelineView fires on real wall time (it can't see AppClock); the
        // body reads `AppClock.now()` so a debug time override flows through
        // to the past/future partition and the "due in …" labels.
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            assignmentList(for: AppClock.now())
        }
    }

    private func assignmentList(for now: Date) -> some View {
        let policy = appState.visualStylePolicy
        // The All tab gets a time-agnostic list, split into past and future here on
        // the `TimelineView` clock, so a row whose `dueDate` just passed moves on the
        // next minute tick. Other tabs sort by `dueDate` alone and pass through as is.
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

    /// A `LazyVStack`, not a `List`. A non-scrolling `List` needs a `.frame(height:)`
    /// from per-row `PreferenceKey` measurements fed into `@State`, which on a tab
    /// switch race the list's `.animation` and hang the UI. Its `.swipeActions`
    /// inside the parent `ScrollView` also flash a black slab above the first row
    /// mid-swipe, which no inset or background tweak silences. `LazyVStack` sizes
    /// itself to its children, and `SwipeableRow` below replaces `.swipeActions`.
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
        // Tapping the row opens the Moodle assignment link; when there is no
        // deep link the tap is a no-op, so don't expose a button trait/hint.
        let tapHint = assignment.moodleDeepLink == nil
            ? nil
            : String(localized: "a11y_assignment_open_moodle_hint")
        return SwipeableRow(
            leadingAction: actions.leading,
            trailingAction: actions.trailing,
            onTap: { openAssignment(assignment) },
            tapHint: tapHint,
            content: content
        )
    }

    private func rowSwipeActions(
        for assignment: SDAssignment,
        now: Date
    ) -> (trailing: SwipeActionDescriptor?, leading: SwipeActionDescriptor?) {
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
        // Default `.center` alignment keeps the trailing status vertically centred
        // even when the title wraps to two lines and the "course name • course ID"
        // line makes the leading column taller than the badge and time stack.
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
        // Overdue + locally completed/archived: show overdue badge
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
            openURL(url)
        }
    }

    private func timeLabel(for assignment: SDAssignment, now: Date) -> String {
        // Past-due rows render the absolute deadline rather than the relative
        // "Overdue" string, which would duplicate the status badge. Matches macOS.
        if showAbsoluteTime || assignment.dueDate < now {
            return assignment.dueDate.absoluteTimeString
        }
        return assignment.dueDate.relativeTimeString(from: now)
    }
}

// MARK: - Swipe gesture helpers

private struct SwipeActionDescriptor {
    let label: String
    let systemImage: String
    let tint: Color
    let action: () -> Void
}

/// Custom horizontal-drag swipe row, standing in for `List.swipeActions` so the
/// assignment list can live in the home `ScrollView` without a `List`: its
/// `.swipeActions` flash a black slab above the first row, and its row diff on
/// a tab switch races `PreferenceKey` height measurement until the UI hangs.
///
/// Drag past `triggerThreshold` either way to run that side's action; release
/// short of it to snap back. The action fires before the spring-back animation
/// so the owning view can remove the row on the frame the spring starts.
private struct SwipeableRow<Content: View>: View {
    let leadingAction: SwipeActionDescriptor?
    let trailingAction: SwipeActionDescriptor?
    let onTap: () -> Void
    /// VoiceOver hint describing what a tap does. `nil` when the row has no
    /// tap destination — the row then exposes neither a button trait nor a
    /// hint so assistive tech doesn't advertise an action that does nothing.
    let tapHint: String?
    let content: Content

    @State private var offset: CGFloat = 0
    /// Set on ANY drag movement (>16pt, any direction); cleared on the
    /// next press-down via `SwipeableButtonStyle`. Prevents swipe and
    /// scroll from accidentally opening Moodle.
    @State private var didSwipe = false

    private let triggerThreshold: CGFloat = 96
    private let snapAnimation = Animation.spring(response: 0.32, dampingFraction: 0.78)

    init(
        leadingAction: SwipeActionDescriptor?,
        trailingAction: SwipeActionDescriptor?,
        onTap: @escaping () -> Void,
        tapHint: String?,
        @ViewBuilder content: () -> Content
    ) {
        self.leadingAction = leadingAction
        self.trailingAction = trailingAction
        self.onTap = onTap
        self.tapHint = tapHint
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
            guard !didSwipe, tapHint != nil else { return }
            onTap()
        } label: {
            content
        }
        .buttonStyle(SwipeableButtonStyle(didSwipe: $didSwipe))
        .contentShape(Rectangle())
        .offset(x: offset)
        .simultaneousGesture(dragGesture)
        .accessibilityAddTraits(tapHint != nil ? .isButton : [])
        .accessibilityHint(tapHint.map { Text($0) } ?? Text(""))
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
