import SwiftUI

/// "Current class" card — surfaces a course whose period block contains
/// the current minute. Sits leftmost in the today carousel so the user's
/// active class is the first thing they see when they open the class
/// table. Mirrors the Android `CurrentClassCard` (red dot + label,
/// course name, classroom, progress bar, time range).
struct CurrentClassCard: View {
    let info: OngoingCourseInfo
    var hasAssignment: Bool = false
    var width: CGFloat? = 200
    var onTap: (() -> Void)? = nil

    var body: some View {
        // Like other clock-derived views, re-subscribe to debug-time
        // flips so the progress bar updates when the override changes.
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

            let classroom = info.course.classroom(for: info.weekday)
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

            Text(timeRange)
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)
        }
        .frame(width: width, alignment: .leading)
        .cardPadding()
        .background(info.course.color.opacity(0.22), in: RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg))
        .glassCard()
        .overlay(alignment: .bottomTrailing) {
            if hasAssignment {
                Image(systemName: "book.closed")
                    .font(.caption2)
                    .foregroundStyle(Color.textSecondary)
                    .padding(8)
            }
        }

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

    private var timeRange: String {
        "\(format(info.startMinute)) - \(format(info.endMinute))"
    }

    private func format(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}
