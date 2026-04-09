import SwiftUI

struct UpcomingAssignmentsView: View {
    let assignments: [SDAssignment]
    var showAbsoluteTime: Bool = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            assignmentList(for: context.date)
        }
    }

    private func assignmentList(for now: Date) -> some View {
        VStack(spacing: TigerDuckTheme.Spacing.sm) {
            ForEach(Array(assignments.enumerated()), id: \.element.assignmentId) { _, assignment in
                Button {
                    if let url = assignment.moodleDeepLink {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(assignment.title)
                                .font(TigerDuckTheme.Typography.body)
                                .foregroundStyle(Color.textPrimary)
                                .lineLimit(1)
                            Text(assignment.courseName)
                                .font(TigerDuckTheme.Typography.caption)
                                .foregroundStyle(Color.textSecondary)
                        }
                        Spacer()
                        Text(timeLabel(for: assignment, now: now))
                            .font(TigerDuckTheme.Typography.caption)
                            .foregroundStyle(assignment.dueDate < now ? Color.badgeRed : Color.textSecondary)
                    }
                    .cardPadding()
                    .glassCard()
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    private func timeLabel(for assignment: SDAssignment, now: Date) -> String {
        if showAbsoluteTime {
            return assignment.dueDate.absoluteTimeString
        } else {
            return assignment.dueDate.relativeTimeString(from: now)
        }
    }
}
