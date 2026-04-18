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
            Text(timeLabel(for: assignment, now: now))
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(assignment.dueDate < now ? Color.badgeRed : policy.secondaryTextColor)

            if policy.assignmentRowStyle == .groupedList {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func openAssignment(_ assignment: SDAssignment) {
        if let url = assignment.moodleDeepLink {
            UIApplication.shared.open(url)
        }
    }

    private func timeLabel(for assignment: SDAssignment, now: Date) -> String {
        if showAbsoluteTime {
            return assignment.dueDate.absoluteTimeString
        } else {
            return assignment.dueDate.relativeTimeString(from: now)
        }
    }
}
