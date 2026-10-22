import SwiftUI

struct CurrentClassCard: View {
    static let defaultWidth: CGFloat = 200

    let info: OngoingCourseInfo
    var hasAssignment: Bool = false
    var width: CGFloat? = CurrentClassCard.defaultWidth
    var onTap: (() -> Void)? = nil

    var body: some View {
        let _ = AppClockState.shared.version

        let card = VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                Text(String(localized: "course_card_current_class"))
                    .font(.caption.bold())
                    .foregroundStyle(Color.textPrimary)
            }

            Text(info.course.displayName)
                .font(TigerDuckTheme.Typography.headline)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2)

            let classroom = info.classroom
            if !classroom.isEmpty {
                Text(classroom)
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(info.course.color)

            Text(info.formattedTimeRange)
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)
        }
        .frame(width: width, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .cardPadding()
        .background(info.course.color.opacity(0.22), in: RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg))
        .glassCard()
        .assignmentBadge(show: hasAssignment)

        if let onTap {
            Button(action: onTap) { card }
                .buttonStyle(.plain)
        } else {
            card
        }
    }

    private var progress: Double {
        let span = info.endMinute - info.startMinute
        guard span > 0 else { return 0 }
        let now = AppClock.now()
        let comps = AppConstants.taipeiCalendar.dateComponents([.hour, .minute], from: now)
        let minute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        return min(max(Double(minute - info.startMinute) / Double(span), 0), 1)
    }
}
