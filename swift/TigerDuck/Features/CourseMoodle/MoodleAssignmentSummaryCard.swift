#if os(iOS)
import SwiftUI
import TigerDuckCore

/// The assignment's due date, with the time left or overdue, and the student's group.
struct MoodleAssignmentSummaryCard: View {
    let due: Date?
    let isSubmitted: Bool?
    let group: String?
    let policy: VisualStylePolicy
    let accent: Color

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title) private var tileWidth: CGFloat = 56
    @ScaledMetric(relativeTo: .title) private var tileHeight: CGFloat = 60

    var body: some View {
        if due != nil || group != nil {
            VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.md) {
                if let due {
                    TimelineView(.everyMinute) { _ in
                        deadline(due, MoodleAssignmentDetails.deadline(due: due, isSubmitted: isSubmitted, now: AppClock.now()))
                    }
                }
                if let group {
                    if due != nil { Divider() }
                    groupRow(group)
                }
            }
            .padding(TigerDuckTheme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .presetCard(policy: policy)
        }
    }

    private func deadline(_ due: Date, _ deadline: MoodleAssignmentDetails.Deadline) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: TigerDuckTheme.Spacing.md))
            : AnyLayout(HStackLayout(spacing: TigerDuckTheme.Spacing.md))
        return layout {
            calendarTile(due, isOverdue: deadline.isOverdue)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "assignment_detail_due"))
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
                Text(MoodleAssignmentDetails.weekdayTimeText(due))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.textPrimary)
                Text(deadline.text)
                    .font(.footnote.weight(deadline.isEmphasized ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(deadline.tint)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "assignment_detail_due"))
        .accessibilityValue("\(MoodleAssignmentDetails.timeText(due)), \(deadline.text)")
    }

    private func calendarTile(_ due: Date, isOverdue: Bool) -> some View {
        VStack(spacing: 0) {
            Text(MoodleAssignmentDetails.monthText(due))
                .font(TigerDuckTheme.Typography.caption.weight(.semibold))
                .foregroundStyle(isOverdue ? Color.badgeRedText : accent)
            Text(verbatim: String(TaipeiTime.calendar.component(.day, from: due)))
                .font(.title.bold())
                .monospacedDigit()
                .foregroundStyle(Color.textPrimary)
        }
        .fixedSize()
        .padding(TigerDuckTheme.Spacing.xs)
        .frame(minWidth: tileWidth, minHeight: tileHeight)
        .background(
            isOverdue ? Color.badgeRed.opacity(0.16) : Color.textPrimary.opacity(0.07),
            in: RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md)
        )
    }

    private func groupRow(_ group: String) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: TigerDuckTheme.Spacing.md))
        let alignment: Alignment = dynamicTypeSize.isAccessibilitySize ? .leading : .trailing
        return layout {
            HStack(spacing: TigerDuckTheme.Spacing.sm) {
                Image(systemName: "person.2")
                    .accessibilityHidden(true)
                Text(String(localized: "assignment_detail_group"))
            }
            .font(.subheadline)
            .foregroundStyle(Color.textSecondary)
            .fixedSize()
            Text(group)
                .font(TigerDuckTheme.Typography.headline)
                .foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                .frame(maxWidth: .infinity, alignment: alignment)
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
