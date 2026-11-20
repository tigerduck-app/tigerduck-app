import SwiftUI

/// Home is one `List`, so each assignment is a row that takes the system's `.swipeActions`.
struct UpcomingAssignmentsView: View {
    static let listChangeAnimation = Animation.snappy(duration: 0.28, extraBounce: 0)

    let assignments: [AssignmentStore.Assignment]
    var courses: [CourseStore.Course] = []
    var filter: AssignmentFilter = .incomplete
    var showAbsoluteTime: Bool = false
    var asListRows = false
    /// Where the rows report their tops, as rows of Home's section `scrollSectionID`.
    var scrollAnchor: HomeScrollAnchor? = nil
    var scrollSectionID = ""
    var onArchive: ((AssignmentStore.Assignment) -> Void)? = nil
    var onMarkComplete: ((AssignmentStore.Assignment) -> Void)? = nil
    var onUnarchive: ((AssignmentStore.Assignment) -> Void)? = nil
    var onUndoComplete: ((AssignmentStore.Assignment) -> Void)? = nil
    var onOpen: (AssignmentStore.Assignment) -> Void = { _ in }

    @Environment(AppEnvironment.self) private var app
    @State private var ticker = MinuteTicker(interval: 60)

    private var courseByNo: [String: CourseStore.Course] {
        Dictionary(courses.map { ($0.courseNo, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        let _ = ticker.tick
        let now = AppClock.now()
        let policy = app.preferences.visualStylePolicy
        let rows = filter == .all
            ? assignments.partitionedByDueDate(now: now)
            : assignments
        if asListRows {
            listRows(rows, policy: policy, now: now)
        } else {
            switch policy.assignmentRowStyle {
            case .card:
                cardLayout(rows: rows, policy: policy, now: now)
            case .groupedList:
                groupedListLayout(rows: rows, policy: policy, now: now)
            }
        }
    }

    private func listRows(_ rows: [AssignmentStore.Assignment], policy: VisualStylePolicy, now: Date) -> some View {
        ForEach(Array(rows.enumerated()), id: \.element.assignmentId) { index, assignment in
            let isFirst = index == 0
            let isLast = index == rows.count - 1
            let actions = rowSwipeActions(for: assignment, now: now)
            let isCard = policy.assignmentRowStyle == .card
            let gap = isCard ? TigerDuckTheme.Spacing.sm / 2 : 0
            Button { onOpen(assignment) } label: {
                if isCard {
                    assignmentRow(assignment: assignment, now: now, policy: policy)
                        .cardPadding()
                        .glassCard()
                } else {
                    groupedRow(assignment: assignment, now: now, policy: policy, isFirst: isFirst, isLast: isLast)
                }
            }
            .buttonStyle(.plain)
            .homeScrollRow(scrollSectionID, in: scrollAnchor)
            .homeListRow(
                top: isFirst ? TigerDuckTheme.Spacing.sm : gap,
                bottom: isLast ? 0 : gap,
                horizontal: TigerDuckTheme.Spacing.lg
            )
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if let leading = actions.leading { swipeButton(leading) }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if let trailing = actions.trailing { swipeButton(trailing) }
            }
            // Icon-only swipe buttons leave the system's swipe actions unnamed, so the row names
            // them for VoiceOver, Voice Control and Switch Control.
            .accessibilityActions {
                ForEach([actions.leading, actions.trailing].compactMap { $0 }, id: \.label) { action in
                    Button(action.label, action: action.action)
                }
            }
        }
    }

    /// One row of the grouped style's rounded container. The container shape runs past the row's
    /// top and bottom edges where a neighbour continues it, and the row clips it there.
    private func groupedRow(
        assignment: AssignmentStore.Assignment,
        now: Date,
        policy: VisualStylePolicy,
        isFirst: Bool,
        isLast: Bool
    ) -> some View {
        let overhang = TigerDuckTheme.CornerRadius.lg
        return assignmentRow(assignment: assignment, now: now, policy: policy)
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .padding(.vertical, TigerDuckTheme.Spacing.md)
            .background(
                Color.clear
                    .presetGroupedListContainer(policy: policy)
                    .padding(.top, isFirst ? 0 : -overhang)
                    .padding(.bottom, isLast ? 0 : -overhang)
                    .clipped()
            )
            .overlay(alignment: .bottom) {
                if !isLast {
                    Divider()
                        .padding(.leading, TigerDuckTheme.Spacing.lg)
                }
            }
    }

    private func swipeButton(_ action: SwipeActionDescriptor) -> some View {
        Button(action: action.action) {
            Label(action.label, systemImage: action.systemImage)
                .labelStyle(.iconOnly)
        }
        .tint(action.tint)
    }

    private func cardLayout(rows: [AssignmentStore.Assignment], policy: VisualStylePolicy, now: Date) -> some View {
        VStack(spacing: TigerDuckTheme.Spacing.sm) {
            ForEach(rows, id: \.assignmentId) { assignment in
                assignmentRow(assignment: assignment, now: now, policy: policy)
                    .cardPadding()
                    .glassCard()
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            }
        }
    }

    private func groupedListLayout(rows: [AssignmentStore.Assignment], policy: VisualStylePolicy, now: Date) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.assignmentId) { index, assignment in
                assignmentRow(assignment: assignment, now: now, policy: policy)
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                    .padding(.vertical, TigerDuckTheme.Spacing.md)

                if index < rows.count - 1 {
                    Divider()
                        .padding(.leading, TigerDuckTheme.Spacing.lg)
                }
            }
        }
        .presetGroupedListContainer(policy: policy)
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    func rowSwipeActions(
        for assignment: AssignmentStore.Assignment,
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
    private func assignmentRow(
        assignment: AssignmentStore.Assignment, now: Date, policy: VisualStylePolicy
    ) -> UpcomingAssignmentRow {
        UpcomingAssignmentRow(
            assignment: assignment, course: courseByNo[assignment.courseNo], now: now, policy: policy,
            showAbsoluteTime: showAbsoluteTime
        )
    }
}

struct SwipeActionDescriptor {
    let label: String
    let systemImage: String
    let tint: Color
    let action: () -> Void
}
