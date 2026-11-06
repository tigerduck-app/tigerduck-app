import SwiftUI
import TigerDuckCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct CourseDetailRoomAndTime: View {
    let course: CourseStore.Course
    let timeRange: String?
    let weekday: Int?
    let periods: [String]?
    let meeting: CourseTimeSlot?

    @Environment(AppEnvironment.self) private var app

    var body: some View {
        EmphasisCards {
            EmphasisCard(
                label: String(localized: "course_detail_classroom_label"),
                value: meeting?.hasChangedRoom == true ? meeting?.room ?? classroomValue : classroomValue,
                isChanged: meeting?.hasChangedRoom == true,
                policy: app.preferences.visualStylePolicy
            )
            EmphasisCard(
                label: String(localized: "course_detail_time_label"),
                value: meeting.flatMap(Self.changedTime) ?? timeValue,
                isChanged: meeting.flatMap(Self.changedTime) != nil,
                policy: app.preferences.visualStylePolicy
            )
        }
    }

    private static func changedTime(_ meeting: CourseTimeSlot) -> String? {
        if meeting.isCancelled { return String(localized: "course_card_cancelled") }
        return meeting.hasChangedTime ? TimeRange.text(meeting.start.timeString, meeting.end.timeString) : nil
    }

    private var classroomValue: String {
        let resolved = Self.classroom(of: course, weekday: weekday, periods: periods)
        return resolved.isEmpty ? "—" : resolved
    }

    static func classroom(of course: CourseStore.Course, weekday: Int?, periods: [String]?) -> String {
        guard let weekday else { return CourseStore.Course.dedup(course.classroom) }
        guard let periods, !periods.isEmpty else { return course.classroom(for: weekday) }
        return course.classroom(weekday: weekday, periods: periods)
    }

    private var timeValue: String {
        if let timeRange, !timeRange.isEmpty { return timeRange }
        if let weekday, let derived = course.timeRange(for: weekday) { return derived }
        return "—"
    }
}

struct CourseDetailInfoRows: View {
    let course: CourseStore.Course

    @State private var codeCopied = false
    @State private var copyFeedback = 0

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.md) {
            DetailInfoRow(
                label: String(localized: "course_detail_instructor_label"),
                value: course.instructor.isEmpty ? "—" : course.instructor
            )
            DetailInfoRow(
                label: String(localized: "course_detail_code_label"),
                value: course.courseNo,
                copied: codeCopied,
                onTap: copyCourseCode
            )
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
        .sensoryFeedback(.success, trigger: copyFeedback)
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

    private func copyCourseCode() {
        #if canImport(UIKit)
        UIPasteboard.general.string = course.courseNo
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(course.courseNo, forType: .string)
        #endif
        copyFeedback += 1
        AccessibilityNotification.Announcement(
            String(localized: "course_detail_code_copied")
        ).post()
        let generation = copyFeedback
        withAnimation { codeCopied = true }
        Task { @MainActor in
            try? await AppClock.sleep(until: ContinuousClock.now + .seconds(1.5))
            guard copyFeedback == generation else { return }
            withAnimation { codeCopied = false }
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
    var isChanged = false
    let policy: VisualStylePolicy

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
            Text(label)
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(value)
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

struct DetailInfoRow: View {
    let label: String
    let value: String
    var copied: Bool = false
    var onTap: (() -> Void)? = nil

    var body: some View {
        if let onTap {
            Button(action: onTap) { content }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(label), \(value)"))
                .accessibilityHint(Text(String(localized: "course_detail_copy_code")))
        } else {
            content
        }
    }

    private var content: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(Color.textSecondary)
            Spacer()
            if onTap != nil {
                if copied {
                    Image(systemName: "checkmark")
                        .font(TigerDuckTheme.Typography.caption)
                        .foregroundStyle(.tint)
                } else {
                    Image(systemName: "doc.on.doc")
                        .font(TigerDuckTheme.Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                }
            }
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
