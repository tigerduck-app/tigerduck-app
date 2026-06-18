import SwiftUI

struct UpcomingAssignmentsView: View {
    private static let listChangeAnimation = Animation.snappy(duration: 0.28, extraBounce: 0)

    let assignments: [SDAssignment]
    /// In-memory course roster used to resolve the canonical display name
    /// and course code for the third row line. Without this, the row falls
    /// back to `assignment.courseName` (Moodle fullname with the code
    /// stripped, fragile) and `assignment.courseNo` (empty when Moodle's
    /// `idnumber` lacks the semester prefix), so the "課名 • 課程ID" line
    /// looked wrong or dropped the ID entirely.
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
        // For the 全部 tab the view model hands us a time-agnostic
        // candidate list; the past/future partition runs here against the
        // `TimelineView` clock so a row whose `dueDate` just crossed `now`
        // re-buckets on the next minute tick instead of staying frozen
        // against whichever `Date()` the view model captured at filter
        // change. Other tabs already sort by `dueDate` only, no live-clock
        // dependency — pass them through as-is.
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

    /// Card layout was previously a `List` with `scrollDisabled(true)` and an
    /// explicit `.frame(height:)` derived from per-row measurements. Two real
    /// problems forced the move to `LazyVStack`:
    ///   • Switching tabs while rows animated in/out fed `PreferenceKey`
    ///     updates back into `@State`, racing with the `.animation` on the
    ///     `assignments` identity and hanging the UI.
    ///   • `List` + `.swipeActions` inside a parent `ScrollView` rendered a
    ///     transient black slab above the first row mid-swipe — a `List`
    ///     edge artifact that no inset / background tweak silenced.
    /// `LazyVStack` sizes itself to its children and the custom `SwipeableRow`
    /// (below) replaces `.swipeActions` so neither issue can recur.
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
        case .pending, .overdueAcceptable, .overdueRejected, .locallyCompleted:
            trailing = SwipeActionDescriptor(label: String(localized: "assignment_ignore"), systemImage: "archivebox.fill", tint: gray) { onArchive?(assignment) }
        case .archived:
            trailing = SwipeActionDescriptor(label: String(localized: "assignment_ignore_undo"), systemImage: "arrow.uturn.backward", tint: gray) { onUnarchive?(assignment) }
        default:
            trailing = nil
        }

        let leading: SwipeActionDescriptor?
        switch status {
        case .pending, .overdueAcceptable, .overdueRejected, .archived:
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
        // Default `.center` alignment vertically centres the trailing status
        // even when the title wraps to two lines (third "課名 • 課程ID" line
        // makes the leading column taller than the badge + time stack).
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
            if let underlyingBadge = underlyingOverdueBadge(for: assignment, status: status, now: now) {
                Text(underlyingBadge.label)
                    .font(statusFont(status: underlyingBadge.status))
                    .foregroundStyle(underlyingBadge.status.tint)
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

    private func underlyingOverdueBadge(
        for assignment: SDAssignment,
        status: AssignmentStatus,
        now: Date
    ) -> (label: String, status: AssignmentStatus)? {
        guard status == .locallyCompleted || status == .archived else { return nil }
        guard assignment.dueDate < now else { return nil }
        if let cutoff = assignment.cutoffDate, now > cutoff {
            return (AssignmentStatus.overdueRejected.badgeLabel!, .overdueRejected)
        }
        return (AssignmentStatus.overdueAcceptable.badgeLabel!, .overdueAcceptable)
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

    /// Past rows always render the absolute deadline so an overdue row reads
    /// `已逾期 / 4/1 23:50` instead of duplicating the "Overdue" badge with
    /// `relativeTimeString`'s own "Overdue" return. Matches macOS.
    private func timeLabel(for assignment: SDAssignment, now: Date) -> String {
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

/// Custom horizontal-drag swipe row.
///
/// Reproduces the swipe-to-act behaviour we previously got from
/// `List.swipeActions` so the assignment list can live inside the home
/// `ScrollView` without the surrounding `List` (whose first-row
/// `.swipeActions` consistently flashed a black slab above the row, and
/// whose row diff during tab switches raced with `PreferenceKey`-based
/// height measurement until it hung).
///
/// Threshold-based: drag past `triggerThreshold` in either direction to
/// execute the corresponding action; release below the threshold to snap
/// back. The action callback fires before the spring-back animation so the
/// owning view can remove the row on the same frame the spring kicks off.
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
    /// Set the instant the drag moves the row; cleared on the next Button
    /// press-down (touch-down of the following interaction). Owned by
    /// `dragGesture` + the tap's `onPressChanged` hook; the tap action only
    /// reads it. See `tappableContent` for why this exists.
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
        if let tapHint {
            // A real `Button` (not `.onTapGesture`) so the first tap wins iOS 18
            // gesture arbitration against Home's ScrollView instead of needing a
            // second press; the swipe-to-reveal drag rides alongside via
            // `.simultaneousGesture` so it isn't blocked. `Button` supplies the
            // `.isButton` trait automatically.
            content
                .offset(x: offset)
                .scrollSafeTapAction(
                    onPressChanged: { isPressed in
                        // Touch-down of a fresh interaction clears the swipe
                        // latch. The Button reports `isPressed == true` before
                        // it ever delivers its tap action on release, and
                        // `dragGesture` only sets `didSwipe` once the row moves,
                        // so the latch always reflects the current interaction
                        // — no ordering or timer assumptions about when the
                        // simultaneous tap/drag callbacks fire.
                        if isPressed { didSwipe = false }
                    }
                ) {
                    // A swipe-release also delivers a Button tap because the
                    // drag rides alongside via `.simultaneousGesture`. `didSwipe`
                    // is set the moment the drag moves the row and stays set
                    // until the next press-down, so this tap reliably bows out
                    // and lets `dragGesture.onEnded` solely own the swipe action
                    // + snap-back. Reading shared `offset` here instead raced:
                    // `onEnded` always resets it to 0, so the tap and the
                    // drag-end could each see the other's reset and the row would
                    // either skip its swipe action or navigate right after it.
                    guard !didSwipe else { return }
                    onTap()
                }
                .simultaneousGesture(dragGesture)
                .accessibilityHint(Text(tapHint))
        } else {
            // No tap destination: keep the row non-interactive (no button trait)
            // while still swipeable.
            content
                .contentShape(Rectangle())
                .offset(x: offset)
                .gesture(dragGesture)
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
                let dx = value.translation.width
                let dy = value.translation.height
                // Defer to the parent ScrollView for primarily-vertical drags
                // so the home page can still scroll while a finger is over a row.
                guard abs(dx) > abs(dy) * 1.3 else { return }
                if dx > 0 && leadingAction == nil { return }
                if dx < 0 && trailingAction == nil { return }
                offset = dx
                // Mark the gesture a swipe the moment it moves the row, so the
                // simultaneous Button tap on release bows out of `onTap()`.
                didSwipe = true
            }
            .onEnded { _ in
                // `offset` is only ever mutated by horizontal-intent updates
                // in `onChanged`, so reading it here (instead of the raw
                // translation) is what gates the trigger on the same
                // dx-vs-dy rule. A mostly-vertical scroll that happens to
                // accumulate >threshold horizontal drift never moves the
                // row, so `offset` stays 0 and no action fires.
                let triggered = abs(offset) > triggerThreshold
                if triggered, let action = (offset > 0 ? leadingAction : trailingAction) {
                    action.action()
                }
                snapBack()
                // `didSwipe` is intentionally NOT cleared here: it must outlive
                // the simultaneous Button tap this release also delivers, whose
                // ordering relative to `onEnded` is undefined. The next
                // interaction's press-down clears it (see `tappableContent`).
            }
    }

    private func snapBack() {
        withAnimation(snapAnimation) {
            offset = 0
        }
    }
}
