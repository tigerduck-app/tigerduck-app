import SwiftUI
import TigerDuckCore

struct CourseDetailRoomAndTime: View {
    let course: CourseStore.Course
    let times: (start: String, end: String)?
    let weekday: Int?
    let periods: [String]?
    let meeting: CourseTimeSlot?
    let policy: VisualStylePolicy

    var body: some View {
        let time = Self.time(of: course, times: times, weekday: weekday, meeting: meeting)
        EmphasisCards {
            LocationCard(
                label: String(localized: "course_detail_location_label"),
                location: location,
                isChanged: meeting?.hasChangedRoom == true,
                policy: policy
            )
            EmphasisCard(
                label: String(localized: "course_detail_time_label"),
                value: time.text,
                spokenValue: time.spoken,
                isChanged: time.isChanged,
                policy: policy
            )
        }
    }

    static func time(
        of course: CourseStore.Course, times: (start: String, end: String)?, weekday: Int?, meeting: CourseTimeSlot?
    ) -> (text: String, spoken: String, isChanged: Bool) {
        if meeting?.isCancelled == true {
            let cancelled = String(localized: "course_card_cancelled")
            return (cancelled, cancelled, true)
        }
        if let meeting, meeting.hasChangedTime {
            let start = meeting.start.timeString, end = meeting.end.timeString
            return (TimeRange.text(start, end), TimeRange.spoken(start, end), true)
        }
        guard let shown = times ?? weekday.flatMap({ course.times(for: $0) }) else { return ("—", "—", false) }
        return (TimeRange.text(shown.start, shown.end), TimeRange.spoken(shown.start, shown.end), false)
    }

    private var location: String {
        if let meeting, meeting.hasChangedRoom { return meeting.room }
        return Self.classroom(of: course, weekday: weekday, periods: periods)
    }

    static func classroom(of course: CourseStore.Course, weekday: Int?, periods: [String]?) -> String {
        guard let weekday else { return CourseStore.Course.dedup(course.classroom) }
        guard let periods, !periods.isEmpty else { return course.classroom(for: weekday) }
        return course.classroom(weekday: weekday, periods: periods)
    }

}

struct CourseDetailInfoRows: View {
    let course: CourseStore.Course

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.md) {
            CopyableDetailRow.instructor(course.instructor)
            CopyableDetailRow.code(course.courseNo)
            if !course.dimension.isEmpty {
                DetailInfoRow(
                    label: String(localized: "course_detail_dimension_label"),
                    value: course.dimension
                )
            }
            if let duration = durationText {
                DetailInfoRow(
                    label: String(localized: "course_detail_duration_label"),
                    value: duration
                )
            }
            if let requireOption = Self.requireOptionText(course.requireOption) {
                DetailInfoRow(
                    label: String(localized: "course_detail_require_option_label"),
                    value: requireOption
                )
            }
            DetailInfoRow(
                label: String(localized: "course_detail_credits_label"),
                value: course.credits.creditsText
            )
            DetailInfoRow(
                label: String(localized: "course_detail_enrollment_label"),
                value: "\(course.enrolledCount) / \(course.maxCount)"
            )
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    private var durationText: String? {
        switch course.allYear.uppercased() {
        case "F": return String(localized: "course_detail_duration_full_year")
        case "H": return String(localized: "course_detail_duration_one_semester")
        default: return nil
        }
    }

    static func requireOptionText(_ requireOption: String) -> String? {
        switch requireOption.uppercased() {
        case "R": return String(localized: "course_detail_require_option_required")
        case "E": return String(localized: "course_detail_require_option_elective")
        default: return nil
        }
    }
}

struct EmphasisCards<Content: View>: View {
    @ViewBuilder let content: Content

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: TigerDuckTheme.Spacing.md))
            : AnyLayout(HStackLayout(spacing: TigerDuckTheme.Spacing.md))
        layout { content }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }
}

struct EmphasisCard: View {
    let label: String
    let value: String
    var spokenValue: String? = nil
    var isChanged = false
    let policy: VisualStylePolicy

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
            Text(label)
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(value)
                .accessibilityLabel(spokenValue ?? value)
                .font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
                .foregroundStyle(isChanged ? Color.changeInk : Color.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .allowsTightening(true)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity)
        .padding(TigerDuckTheme.Spacing.md)
        .presetCard(policy: policy)
    }
}

struct LocationCard: View {
    let label: String
    let location: String
    var isChanged = false
    let policy: VisualStylePolicy

    var body: some View {
        CopyableValue(text: location, label: label, hint: "class_table_copy_location", toast: "class_table_location_copied") {
            EmphasisCard(label: label, value: $0, isChanged: isChanged, policy: policy)
        }
    }
}

/// The copy shows `toast` through the nearest `toastHost()` above it.
struct CopyableValue<Content: View>: View {
    let text: String
    let label: String
    let hint: LocalizedStringResource
    let toast: LocalizedStringResource
    @ViewBuilder let content: (String) -> Content

    var body: some View {
        let shown = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if shown.isEmpty {
            content("—")
        } else {
            content(shown).modifier(CopyOnTap(text: shown, label: label, hint: hint, toast: toast))
        }
    }
}

private struct CopyOnTap: ViewModifier {
    let text: String
    let label: String
    let hint: LocalizedStringResource
    let toast: LocalizedStringResource

    @Environment(\.showToast) private var showToast
    @State private var copies = 0

    func body(content: Content) -> some View {
        Button {
            Pasteboard.copy(text)
            copies += 1
            showToast(toast)
        } label: {
            content
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "\(label), \(text)"))
        .accessibilityHint(Text(hint))
        .sensoryFeedback(.success, trigger: copies)
    }
}

struct DetailInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(Color.textSecondary)
            Spacer()
            Text(value)
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        // Without this the button only reacts on the label and value text,
        // not on the gap between them.
        .contentShape(Rectangle())
    }
}

struct CopyableDetailRow: View {
    let label: String
    let value: String
    let hint: LocalizedStringResource
    let toast: LocalizedStringResource

    var body: some View {
        CopyableValue(text: value, label: label, hint: hint, toast: toast) { DetailInfoRow(label: label, value: $0) }
    }

    static func instructor(_ instructor: String) -> CopyableDetailRow {
        CopyableDetailRow(
            label: String(localized: "course_detail_instructor_label"), value: instructor,
            hint: "course_detail_copy_instructor", toast: "course_detail_instructor_copied"
        )
    }

    static func code(_ courseNo: String) -> CopyableDetailRow {
        CopyableDetailRow(
            label: String(localized: "course_detail_code_label"), value: courseNo,
            hint: "course_detail_copy_code", toast: "course_detail_code_copied"
        )
    }

    static func location(_ classroom: String) -> CopyableDetailRow {
        CopyableDetailRow(
            label: String(localized: "course_detail_location_label"), value: classroom,
            hint: "class_table_copy_location", toast: "class_table_location_copied"
        )
    }
}
