#if os(macOS)
import SwiftUI

/// In-app widget cards for the Mac home page.
///
/// macOS WidgetKit desktop widgets would require pbxproj surgery on
/// `TigerDuckWidgetsExtension` (currently `SUPPORTED_PLATFORMS =
/// "iphoneos iphonesimulator"`). Until that target picks up Mac, the
/// same TigerDuck Widgets payload is surfaced inside the app as cards
/// on the home page — scoped to the two widgets the user actually
/// asked for: today's schedule and the next class. They read the same
/// underlying `DataCache` the iPhone widgets read so a refresh in the
/// app updates them.
struct MacHomeWidgetsRow: View {
    let courses: [SDCourse]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            content(now: AppClock.now())
        }
    }

    private func content(now: Date) -> some View {
        let slots = todaySlots(for: now)
        return HStack(alignment: .top, spacing: 14) {
            TodayScheduleWidgetCard(slots: slots, now: now)
                .frame(maxWidth: .infinity)
            NextClassWidgetCard(slots: slots, now: now)
                .frame(maxWidth: .infinity)
        }
    }

    private func todaySlots(for now: Date) -> [CourseTimeSlot] {
        let weekday = now.scheduleWeekday
        return CourseTimeSlot.buildSlots(from: courses, weekday: weekday, on: now)
    }
}

// MARK: - Today's schedule

private struct TodayScheduleWidgetCard: View {
    let slots: [CourseTimeSlot]
    let now: Date

    var body: some View {
        widgetCard(title: String(localized: "calendar_today"), systemImage: "calendar.day.timeline.left") {
            if slots.isEmpty {
                empty(label: String(localized: "widget_no_classes_today"))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(slots.prefix(6)) { slot in
                        scheduleRow(slot)
                    }
                    if slots.count > 6 {
                        Text(String(format: String(localized: "desktop_widget_more_count"), slots.count - 6))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func scheduleRow(_ slot: CourseTimeSlot) -> some View {
        let color = TigerDuckTheme.courseColor(for: slot.course.courseNo)
        let isPast = slot.end < now
        let isLive = slot.start <= now && now < slot.end
        return HStack(spacing: 10) {
            Text(slot.start, format: .dateTime.hour().minute())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(slot.course.displayName)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
            if isLive {
                Text(String(localized: "desktop_widget_now"))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(color))
            }
        }
        .opacity(isPast && !isLive ? 0.45 : 1)
    }
}

// MARK: - Next class

private struct NextClassWidgetCard: View {
    let slots: [CourseTimeSlot]
    let now: Date

    var body: some View {
        widgetCard(title: String(localized: "widget_next_class"), systemImage: "arrow.right.circle") {
            if let target = nextOrCurrent {
                let color = TigerDuckTheme.courseColor(for: target.slot.course.courseNo)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(target.label.uppercased())
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(target.slot.course.timeRange(for: target.slot.date.scheduleWeekday) ?? "")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(color)
                    }
                    Text(target.slot.course.displayName)
                        .font(.title3.bold())
                        .lineLimit(2)
                    let classroom = target.slot.course.classroom(for: target.slot.date.scheduleWeekday)
                    if !classroom.isEmpty {
                        Label(classroom, systemImage: "mappin.and.ellipse")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(target.countdownLabel(from: now))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.primary)
                        .padding(.top, 2)
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                empty(label: String(localized: "widget_no_more_classes"))
            }
        }
    }

    private var nextOrCurrent: NextClassTarget? {
        if let live = slots.first(where: { $0.start <= now && now < $0.end }) {
            return NextClassTarget(slot: live, label: String(localized: "live_activity_status_in_class"))
        }
        if let next = slots.first(where: { $0.start > now }) {
            return NextClassTarget(slot: next, label: String(localized: "desktop_widget_up_next"))
        }
        return nil
    }
}

private struct NextClassTarget {
    let slot: CourseTimeSlot
    let label: String

    func countdownLabel(from now: Date) -> String {
        if slot.start <= now && now < slot.end {
            let remaining = max(0, Int(slot.end.timeIntervalSince(now)))
            return "Ends in \(format(remaining))"
        }
        let until = max(0, Int(slot.start.timeIntervalSince(now)))
        return "Starts in \(format(until))"
    }

    private func format(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

// MARK: - Shared chrome

@ViewBuilder
private func widgetCard<Content: View>(
    title: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(16)
    .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
    .background(
        RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg, style: .continuous)
            .fill(.ultraThinMaterial)
    )
    .overlay(
        RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg, style: .continuous)
            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
    )
}

private func empty(label: String) -> some View {
    HStack {
        Image(systemName: "checkmark.circle")
            .foregroundStyle(.secondary)
        Text(label)
            .font(.callout)
            .foregroundStyle(.secondary)
        Spacer()
    }
    .frame(maxWidth: .infinity, minHeight: 80)
}
#endif
