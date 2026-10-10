#if os(macOS)
import SwiftUI

/// In-app widget cards for the Mac home page.
///
/// macOS desktop widgets would need pbxproj changes to `TigerDuckWidgetsExtension`, whose
/// `SUPPORTED_PLATFORMS` is `"iphoneos iphonesimulator"`. Until that target supports Mac,
/// two of its widgets, today's schedule and the next class, render here as cards. They
/// read the same `DataCache` as the iPhone widgets, so a refresh in the app updates them.
struct MacHomeWidgetsRow: View {
    let courses: [SDCourse]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            content(now: AppClock.now())
        }
    }

    private func content(now: Date) -> some View {
        let todaySlots = todaySlots(for: now)
        // Next Class scans forward up to a week so an evening view on
        // Monday still surfaces Tuesday's first class, matching the
        // WidgetKit next-class derivation.
        let upcomingSlots = upcomingSlots(for: now)
        return HStack(alignment: .top, spacing: 14) {
            TodayScheduleWidgetCard(slots: todaySlots, now: now)
                .frame(maxWidth: .infinity)
            NextClassWidgetCard(slots: upcomingSlots, now: now)
                .frame(maxWidth: .infinity)
        }
    }

    private func todaySlots(for now: Date) -> [CourseTimeSlot] {
        let weekday = now.scheduleWeekday
        return CourseTimeSlot.buildSlots(from: courses, weekday: weekday, on: now)
            .filter { !$0.course.isSkipped(on: $0.date) }
    }

    private func upcomingSlots(for now: Date) -> [CourseTimeSlot] {
        let calendar = AppConstants.taipeiCalendar
        let start = calendar.startOfDay(for: now)
        var slots: [CourseTimeSlot] = []
        for offset in 0...7 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            let weekday = date.scheduleWeekday
            slots.append(
                contentsOf: CourseTimeSlot.buildSlots(from: courses, weekday: weekday, on: date)
                    .filter { !$0.course.isSkipped(on: $0.date) }
            )
        }
        return slots.sorted { $0.start < $1.start }
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
        // Like the iPhone Today widget: the live row is a solid course-color pill and upcoming
        // rows get a thin colored leading bar, so the course palette reads at a glance instead
        // of hiding behind a 6pt dot.
        let primary: Color = isLive ? .white : .primary
        let secondary: Color = isLive ? Color.white.opacity(0.85) : .secondary
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(isLive ? Color.white.opacity(0.9) : color)
                .frame(width: 3, height: 22)
            Text(slot.start, format: .dateTime.hour().minute())
                .font(.caption.monospacedDigit())
                .foregroundStyle(secondary)
                .frame(width: 48, alignment: .leading)
            Text(slot.course.displayName)
                .font(.callout)
                .foregroundStyle(primary)
                .lineLimit(1)
            Spacer()
            if isLive {
                Text(String(localized: "desktop_widget_now"))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.95)))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isLive ? color : color.opacity(0.10))
        )
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
                let primary = target.slots[0]
                let color = TigerDuckTheme.courseColor(for: primary.course.courseNo)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        // The chosen slot's bounds, not the day's first-to-last span: the
                        // countdown targets `primary.start`, so for a course split across the
                        // day (P3-P4, P7-P8) a span across the gap would not match the timer.
                        Text("\(primary.start.timeString) - \(primary.end.timeString)")
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        // Badge only a class in session: a "next up" caption repeats the card
                        // title, and the white-on-course-color pill is hard to read for several
                        // palette entries. The live state is distinct information, so it keeps one.
                        if case .live = target.kind {
                            Text(String(localized: "live_activity_status_in_class").uppercased())
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(color))
                        }
                    }
                    if target.slots.count >= 2 {
                        // Conflict: list every overlapping course on its own line so
                        // none is hidden. Each name has its own line limit to keep
                        // the card height roughly stable.
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(target.slots, id: \.course.courseNo) { slot in
                                Text(slot.course.displayName)
                                    .font(.title3.bold())
                                    .lineLimit(1)
                            }
                        }
                    } else {
                        Text(primary.course.displayName)
                            .font(.title3.bold())
                            .lineLimit(2)
                        let classroom = primary.course.classroom(for: primary.date.scheduleWeekday)
                        if !classroom.isEmpty {
                            Label(classroom, systemImage: "mappin.and.ellipse")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
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

    /// Returns every slot that shares the same "current" or "next" start
    /// time, so a conflict (two simultaneous classes) shows both courses
    /// instead of silently dropping one. The live branch targets the most
    /// recently started live slot, so a long class still in progress is not
    /// grouped with a different class the user just moved into.
    private var nextOrCurrent: NextClassTarget? {
        let liveSlots = slots.filter { $0.start <= now && now < $0.end }
        if let targetStart = liveSlots.map(\.start).max() {
            let tiedLive = liveSlots.filter { $0.start == targetStart }
            return NextClassTarget(slots: tiedLive, kind: .live)
        }
        guard let earliestNext = slots.filter({ $0.start > now }).min(by: { $0.start < $1.start })
        else { return nil }
        let tied = slots.filter { $0.start == earliestNext.start }
        return NextClassTarget(slots: tied, kind: .upcoming)
    }
}

private struct NextClassTarget {
    enum Kind {
        case live
        case upcoming
    }

    /// 1 entry for a solo class, 2+ for a conflict (every slot sharing the same
    /// start). The countdown reads start from `slots[0]` (all members share it)
    /// and end from the latest finishing slot, so a conflict block of courses with
    /// different period spans still counts down to the moment the block is fully over.
    let slots: [CourseTimeSlot]
    let kind: Kind

    func countdownLabel(from now: Date) -> String {
        let start = slots[0].start
        let end = slots.map(\.end).max() ?? slots[0].end
        if start <= now && now < end {
            let remaining = max(0, Int(end.timeIntervalSince(now)))
            return String(format: String(localized: "desktop_widget_ends_in"), format(remaining))
        }
        let until = max(0, Int(start.timeIntervalSince(now)))
        return String(format: String(localized: "desktop_widget_starts_in"), format(until))
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
