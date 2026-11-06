import SwiftUI
import TigerDuckCore
import WidgetKit

struct WeekHeaderRow: View {
    let snapshot: WidgetSnapshot
    let now: Date
    let palette: WidgetPalette
    let family: WidgetFamily
    let size: CGFloat
    let periodWidth: CGFloat
    let height: CGFloat
    let spacing: CGFloat

    private var showsDates: Bool { family.isExtraLargePortrait || family == .systemExtraLarge }

    var body: some View {
        let weekdays = snapshot.activeWeekdays
        let today = ClassTimeline.weekday(of: now)
        return HStack(spacing: spacing) {
            Group {
                if let week = snapshot.term?.week(on: now) {
                    Text(verbatim: "W\(week)")
                        .font(.system(size: size - 1, weight: .bold))
                        .foregroundStyle(palette.onSurfaceVariant)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .accessibilityLabel(Text(String(format: String(localized: "a11y_class_table_week"), week)))
                } else {
                    Color.clear
                }
            }
            .frame(width: periodWidth, height: height)
            ForEach(weekdays, id: \.self) { weekday in
                dayHeader(weekday, isToday: weekday == today)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
            }
        }
    }

    @ViewBuilder
    private func dayHeader(_ weekday: Int, isToday: Bool) -> some View {
        let name = Text(WidgetDayHeader.weekdayKey(weekday)).font(.system(size: showsDates ? size + 1 : size, weight: .bold))
        if showsDates {
            let day = TaipeiTime.calendar.component(.day, from: WeekGridView.day(of: weekday, from: now))
            let marked = Text(String(day))
                .font(.system(size: size, weight: isToday ? .bold : .regular))
                .monospacedDigit()
                .foregroundStyle(isToday ? .white : palette.onSurfaceVariant)
                .padding(.horizontal, 4)
                .todayMark(isToday, in: Capsule(), palette: palette)
            if family.isExtraLargePortrait {
                VStack(spacing: 1) {
                    name.foregroundStyle(isToday ? palette.highlight : palette.onSurfaceVariant)
                    marked
                }
            } else {
                HStack(spacing: 4) {
                    name.foregroundStyle(isToday ? palette.highlight : palette.onSurfaceVariant)
                    marked
                }
            }
        } else {
            name
                .foregroundStyle(isToday ? .white : palette.onSurfaceVariant)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 4)
                .frame(minWidth: size * 1.6, minHeight: size * 1.6)
                .todayMark(isToday, in: Capsule(), palette: palette)
        }
    }
}

struct WeekCourseBlock: View {
    let course: SnapshotCourse
    let classroom: String
    let change: SnapshotCourseChange?
    let times: PeriodTime?
    let progress: Double?
    let palette: WidgetPalette
    let family: WidgetFamily
    let size: CGFloat
    let radius: CGFloat

    private var isCancelled: Bool { change?.cancelled == true }

    var body: some View {
        let tile = palette.tile(course.colorHex, isPast: isCancelled)
        let changedTime = isCancelled ? nil : TimeRange.partial(start: change?.start, end: change?.end)
        let spoken = [
            course.displayName,
            changedTime.map { spokenChangedTime ?? $0 },
            isCancelled ? String(localized: "course_card_cancelled") : classroom,
        ]
        return VStack(alignment: .leading, spacing: 1) {
            if let changedTime {
                Label(changedTime, systemImage: "clock.fill")
                    .labelStyle(ChangedValueLabelStyle())
                    .font(.system(size: size - 2, weight: .semibold).monospacedDigit())
                    .foregroundStyle(palette.changeInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(course.displayName)
                .font(.courseName(size, weight: .medium))
                .strikethrough(isCancelled)
                .foregroundStyle(tile.ink)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            bottom(tile: tile)
        }
        .padding(.horizontal, family == .systemLarge ? 4 : 5)
        .padding(.vertical, family == .systemLarge ? 3 : 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .classTile(tile, radius: radius, progress: progress, outline: 1.5, bottomBar: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
    }

    private func bottom(tile: WidgetTile) -> some View {
        Group {
            if isCancelled {
                Text(String(localized: "course_card_cancelled"))
                    .font(.system(size: size - 1, weight: .semibold))
                    .foregroundStyle(tile.secondaryInk)
            } else {
                WidgetRoom(
                    room: classroom, changed: change?.room != nil, font: .system(size: size, weight: .bold),
                    ink: tile.ink, changeInk: palette.changeInk
                )
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .layoutPriority(1)
    }

    private var spokenChangedTime: String? {
        guard let start = change?.start ?? times?.start, let end = change?.end ?? times?.end else { return nil }
        return TimeRange.spoken(start, end)
    }
}

private extension View {
    @ViewBuilder
    func todayMark(_ isToday: Bool, in shape: some InsettableShape, palette: WidgetPalette) -> some View {
        if !isToday {
            self
        } else if palette.isFullColor {
            background(palette.highlight, in: shape)
        } else {
            overlay { shape.strokeBorder(.white, lineWidth: 1.5) }
        }
    }
}
