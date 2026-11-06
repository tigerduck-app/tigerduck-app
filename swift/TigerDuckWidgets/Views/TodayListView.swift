import SwiftUI
import TigerDuckCore
import WidgetKit

struct TodayView: View {
    let snapshot: WidgetSnapshot
    let now: Date
    let palette: WidgetPalette
    let family: WidgetFamily

    var body: some View {
        Group {
            if !snapshot.isLoggedIn {
                TodayMessage(key: "widget_sign_in", palette: palette)
            } else if family.isExtraLargePortrait {
                TodayTimelineView(snapshot: snapshot, now: now, palette: palette)
            } else if family == .systemMedium {
                TodayMediumList(snapshot: snapshot, now: now, palette: palette)
            } else if family == .systemExtraLarge {
                extraLarge
            } else {
                TodayColumn(day: now, rows: WidgetDayLayout.rows(snapshot: snapshot, on: now, now: now), palette: palette)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var extraLarge: some View {
        let tomorrow = TaipeiTime.calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let tomorrowRows = WidgetDayLayout.rows(snapshot: snapshot, on: tomorrow, now: now)
        HStack(spacing: 20) {
            TodayColumn(day: now, rows: WidgetDayLayout.rows(snapshot: snapshot, on: now, now: now), palette: palette)
            if !tomorrowRows.isEmpty {
                Rectangle()
                    .fill(palette.onSurfaceVariant.opacity(0.2))
                    .frame(width: 1)
                TodayColumn(
                    day: tomorrow, title: String(localized: "widget_tomorrow"), rows: tomorrowRows, palette: palette
                )
            }
        }
    }
}

struct TodayMessage: View {
    let key: LocalizedStringResource
    let palette: WidgetPalette

    var body: some View {
        Text(key)
            .font(.callout)
            .foregroundStyle(palette.onSurfaceVariant)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func noClasses(on day: Date) -> LocalizedStringResource {
        ClassTimeline.weekday(of: day) >= 6 ? "widget_no_classes_weekend" : "widget_no_classes_today"
    }
}

struct TodayColumn: View {
    let day: Date
    var title: String? = nil
    let rows: [WidgetClassRow]
    let palette: WidgetPalette

    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 46
    private let spacing: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetDayHeader(day: day, title: title, titleFont: .headline, dateFont: .footnote, palette: palette)
            if rows.isEmpty {
                TodayMessage(key: TodayMessage.noClasses(on: day), palette: palette)
            } else {
                GeometryReader { geometry in
                    let limit = max(1, Int((geometry.size.height + spacing) / (rowHeight + spacing)))
                    VStack(spacing: spacing) {
                        ForEach(WidgetDayLayout.window(rows, limit: limit)) { row in
                            TodayColumnRow(item: row, height: rowHeight, palette: palette)
                        }
                    }
                }
            }
        }
    }
}

private struct TodayColumnRow: View {
    let item: WidgetClassRow
    let height: CGFloat
    let palette: WidgetPalette

    @ScaledMetric(relativeTo: .subheadline) private var nameSize: CGFloat = 15

    var body: some View {
        let row = item.row
        let tile = palette.tile(row.course.colorHex, isPast: item.isPast || row.isCancelled)
        let timeChanged = !row.isCancelled && (row.change?.start ?? row.change?.end) != nil
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text(row.startTime)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(timeChanged ? palette.changeInk : item.isPast ? palette.onSurfaceVariant : palette.onSurface)
                Text(row.endTime)
                    .font(.caption)
                    .foregroundStyle(timeChanged ? palette.changeInk : palette.onSurfaceVariant)
            }
            .monospacedDigit()
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(TimeRange.spoken(row.startTime, row.endTime))
            VStack(alignment: .leading, spacing: 4) {
                NameRoomLine(
                    name: row.course.displayName, room: row.classroom, roomChanged: row.change?.room != nil,
                    isCancelled: row.isCancelled, nameFont: .courseName(nameSize, weight: .semibold),
                    roomFont: .subheadline.weight(.bold), ink: tile.ink, changeInk: palette.changeInk
                )
                if row.isCancelled {
                    Text(String(localized: "course_card_cancelled"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tile.secondaryInk)
                } else if let progress = item.progress {
                    ProgressCapsule(progress: progress, tile: tile)
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .classTile(tile, radius: 10, progress: item.progress, outline: 2, bottomBar: false)
        }
        .frame(height: height)
        .accessibilityElement(children: .combine)
    }
}

struct TodayMediumList: View {
    let snapshot: WidgetSnapshot
    let now: Date
    let palette: WidgetPalette

    @ScaledMetric(relativeTo: .footnote) private var rowHeight: CGFloat = 24
    @ScaledMetric(relativeTo: .footnote) private var nameSize: CGFloat = 13
    private let spacing: CGFloat = 4

    var body: some View {
        let rows = WidgetDayLayout.rows(snapshot: snapshot, on: now, now: now)
        let upcoming = rows.filter { !$0.isPast }
        VStack(alignment: .leading, spacing: 6) {
            WidgetDayHeader(day: now, titleFont: .footnote.weight(.bold), dateFont: .caption, palette: palette)
            if rows.isEmpty {
                TodayMessage(key: TodayMessage.noClasses(on: now), palette: palette)
            } else if upcoming.isEmpty {
                TodayMessage(key: "widget_no_more_classes", palette: palette)
            } else {
                GeometryReader { geometry in
                    let limit = max(1, Int((geometry.size.height + spacing) / (rowHeight + spacing)))
                    VStack(spacing: spacing) {
                        ForEach(upcoming.prefix(limit)) { item in
                            row(item)
                        }
                    }
                }
            }
        }
    }

    private func row(_ item: WidgetClassRow) -> some View {
        let row = item.row
        let tile = palette.tile(row.course.colorHex, isPast: row.isCancelled)
        let timeChanged = !row.isCancelled && row.change?.start != nil
        return HStack(spacing: 8) {
            Text(row.startTime)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(timeChanged ? palette.changeInk : palette.onSurface)
                .fixedSize()
            NameRoomLine(
                name: row.course.displayName, room: row.classroom, roomChanged: row.change?.room != nil,
                isCancelled: row.isCancelled, nameFont: .courseName(nameSize, weight: .medium), roomFont: .footnote.weight(.bold),
                ink: tile.ink, changeInk: palette.changeInk
            )
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .classTile(tile, radius: 6, progress: item.progress, outline: 1.5, bottomBar: true)
        }
        .frame(height: rowHeight)
        .accessibilityElement(children: .combine)
    }
}

struct TodayTimelineView: View {
    let snapshot: WidgetSnapshot
    let now: Date
    let palette: WidgetPalette

    @ScaledMetric(relativeTo: .subheadline) private var nameSize: CGFloat = 15
    @ScaledMetric(relativeTo: .footnote) private var shortNameSize: CGFloat = 13
    private let gutter: CGFloat = 34

    var body: some View {
        let rows = WidgetDayLayout.rows(snapshot: snapshot, on: now, now: now)
        VStack(alignment: .leading, spacing: 8) {
            WidgetDayHeader(day: now, titleFont: .title3.weight(.bold), dateFont: .footnote, palette: palette)
            if let hours = WidgetDayLayout.hours(of: rows) {
                GeometryReader { geometry in
                    let perMinute = geometry.size.height / CGFloat((hours.upperBound - hours.lowerBound) * 60)
                    let y = { (minute: Int) in CGFloat(minute - hours.lowerBound * 60) * perMinute }
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(hours), id: \.self) { hour in
                            hourMark(hour, width: geometry.size.width).offset(y: y(hour * 60))
                        }
                        let lanes = Self.lanes(of: rows)
                        let laneWidth = (geometry.size.width - gutter - 4) / CGFloat(max(lanes.count, 1))
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                            card(item, height: max(CGFloat(item.end - item.start) * perMinute - 2, 14))
                                .frame(width: laneWidth - 2)
                                .offset(x: gutter + 4 + CGFloat(lanes.lane[index]) * laneWidth, y: y(item.start) + 1)
                        }
                        if let minute = WidgetDayLayout.nowLine(rows: rows, now: now) {
                            nowLine(minute, width: geometry.size.width).offset(y: y(minute))
                        }
                    }
                }
                .padding(.top, 7)
            } else {
                TodayMessage(key: TodayMessage.noClasses(on: now), palette: palette)
            }
        }
    }

    private func hourMark(_ hour: Int, width: CGFloat) -> some View {
        HStack(spacing: 4) {
            Text(String(format: "%02d", hour))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(palette.onSurfaceVariant)
                .frame(width: gutter - 4, alignment: .leading)
            Rectangle()
                .fill(palette.onSurfaceVariant.opacity(0.18))
                .frame(height: 1)
        }
        .frame(width: width, height: 14)
        .offset(y: -7)
        .accessibilityHidden(true)
    }

    private func nowLine(_ minute: Int, width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(palette.highlight)
                .frame(width: width - gutter, height: 2)
                .offset(x: gutter)
            Circle()
                .fill(palette.highlight)
                .frame(width: 8, height: 8)
                .offset(x: gutter - 4)
            Text(String(format: "%02d:%02d", minute / 60, minute % 60))
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(palette.highlight)
                .fixedSize()
                .background(palette.canvas)
        }
        .frame(width: width, height: 14, alignment: .leading)
        .offset(y: -7)
        .widgetAccentable()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func card(_ item: WidgetClassRow, height: CGFloat) -> some View {
        let row = item.row
        let tile = palette.tile(row.course.colorHex, isPast: item.isPast || row.isCancelled)
        let tall = height >= 56
        let line = NameRoomLine(
            name: row.course.displayName, room: row.classroom, roomChanged: row.change?.room != nil,
            isCancelled: row.isCancelled, nameFont: .courseName(tall ? nameSize : shortNameSize, weight: .semibold),
            roomFont: (tall ? Font.subheadline : .footnote).weight(.bold), ink: tile.ink, changeInk: palette.changeInk
        )
        VStack(alignment: .leading, spacing: 2) {
            line
            if tall {
                Text(row.isCancelled ? String(localized: "course_card_cancelled") : TimeRange.text(row.startTime, row.endTime))
                    .accessibilityLabel(
                        row.isCancelled ? String(localized: "course_card_cancelled") : TimeRange.spoken(row.startTime, row.endTime)
                    )
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(row.change?.start ?? row.change?.end != nil ? palette.changeInk : tile.secondaryInk)
                Spacer(minLength: 0)
                if let progress = item.progress {
                    ProgressCapsule(progress: progress, tile: tile)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, tall ? 8 : 0)
        .frame(height: height, alignment: tall ? .topLeading : .leading)
        .classTile(tile, radius: tall ? 10 : 8, progress: item.progress, outline: 2, bottomBar: false)
        .accessibilityElement(children: .combine)
    }

    static func lanes(of rows: [WidgetClassRow]) -> (lane: [Int], count: Int) {
        var laneEnds: [Int] = []
        let lane = rows.map { row in
            if let free = laneEnds.firstIndex(where: { $0 <= row.start }) {
                laneEnds[free] = row.end
                return free
            }
            laneEnds.append(row.end)
            return laneEnds.count - 1
        }
        return (lane, laneEnds.count)
    }
}
