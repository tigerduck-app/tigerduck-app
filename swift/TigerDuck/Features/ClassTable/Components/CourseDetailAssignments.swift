import SwiftUI

/// The course's unfinished assignments on its sheet; a tap opens one.
struct CourseDetailAssignments: View {
    let assignments: [AssignmentStore.Assignment]
    let open: (AssignmentStore.Assignment) -> Void

    @ViewBuilder
    var body: some View {
        if !assignments.isEmpty {
            Divider().background(Color.textSecondary)
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)

            Text(String(localized: "course_detail_incomplete_assignments"))
                .font(TigerDuckTheme.Typography.headline)
                .foregroundStyle(Color.textPrimary)
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)

            ForEach(Array(assignments.enumerated()), id: \.element.assignmentId) { _, assignment in
                Button {
                    open(assignment)
                } label: {
                    HStack {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(assignment.displayTitle)
                                .font(TigerDuckTheme.Typography.body)
                                .foregroundStyle(Color.textPrimary)
                            Text(String(format: String(localized: "course_detail_due_prefix"), assignment.dueDate.shortDateString))
                                .font(TigerDuckTheme.Typography.caption)
                                .foregroundStyle(assignment.isOverdue ? Color.badgeRed : Color.textSecondary)
                        }
                        Spacer()
                        Image(systemName: Self.assignmentAccessory)
                            .foregroundStyle(Color.textSecondary)
                            .font(.caption)
                    }
                    .cardPadding()
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .glassCard()
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            }
        }
    }

    #if os(macOS)
    private static let assignmentAccessory = "arrow.up.right.square"
    #else
    private static let assignmentAccessory = "chevron.right"
    #endif
}
