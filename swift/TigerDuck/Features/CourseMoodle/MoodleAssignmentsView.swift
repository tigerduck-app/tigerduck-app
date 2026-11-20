import SwiftUI

struct MoodleAssignmentsView: View {
    let store: MoodleCourseStore
    let policy: VisualStylePolicy
    let refresh: () async -> Void
    let open: (MoodleCourseAssignments.Entry) -> Void

    struct Row: Identifiable {
        let entry: MoodleCourseAssignments.Entry
        let status: AssignmentStatus?

        var id: Int { entry.id }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            ScrollView {
                card(Self.rows(of: store.assignments.list, now: AppClock.now()))
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                    .padding(.vertical, TigerDuckTheme.Spacing.xs)
            }
        }
        .background(Color.backgroundPrimary)
        .refreshable { await refresh() }
        .moodleListChrome(
            title: String(localized: "course_detail_assignments_label"),
            page: .assignments(courseId: store.courseId),
            refresh: refresh
        )
    }

    static func rows(of entries: [MoodleCourseAssignments.Entry], now: Date) -> [Row] {
        entries.partitionedByDueDate(\.dueDate, title: \.title, now: now).map { entry in
            Row(entry: entry, status: entry.listed.flatMap { shownStatus(of: $0, now: now) })
        }
    }

    static func shownStatus(of assignment: AssignmentStore.Assignment, now: Date) -> AssignmentStatus? {
        switch assignment.moodleStatus(now: now) {
        case .submitted: .submitted
        case .submittedLate: .submittedLate
        case .overdueAcceptable, .overdueRejected: .overdueAcceptable
        case .pending, .archived, .locallyCompleted: nil
        }
    }

    private func card(_ rows: [Row]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Divider().padding(.leading, TigerDuckTheme.Spacing.lg)
                }
                Button {
                    open(row.entry)
                } label: {
                    MoodleAssignmentRow(row: row)
                }
                .buttonStyle(.plain)
                .moodleRowHover()
            }
        }
        .presetCard(policy: policy)
    }
}

private struct MoodleAssignmentRow: View {
    let row: MoodleAssignmentsView.Row

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = dynamicTypeSize.rowLayout
        HStack(spacing: TigerDuckTheme.Spacing.md) {
            layout {
                Text(row.entry.title)
                    .font(TigerDuckTheme.Typography.body)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(stacked ? nil : 2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: stacked ? .leading : .trailing, spacing: 2) {
                    if let status = row.status, let label = status.badgeLabel {
                        Text(label)
                            .font(TigerDuckTheme.Typography.caption.weight(.semibold))
                            .foregroundStyle(status.tint)
                    }
                    Text(row.entry.dueDate?.absoluteMinuteString ?? "—")
                        .font(TigerDuckTheme.Typography.caption)
                        .monospacedDigit()
                        .foregroundStyle(Color.textSecondary)
                        .accessibilityHidden(row.entry.dueDate == nil)
                }
                .fixedSize()
            }
            Image(systemName: Self.accessory)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.textSecondary.opacity(0.5))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.vertical, TigerDuckTheme.Spacing.md)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    #if os(macOS)
    private static let accessory = "arrow.up.right.square"
    #else
    private static let accessory = "chevron.right"
    #endif
}
