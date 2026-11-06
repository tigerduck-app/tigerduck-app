import SwiftUI
import WidgetKit
import TigerDuckCore

struct NextClassView: View {
    let derived: WidgetDerivedState
    var upNext: WidgetDerivedState.NextInfo? = nil
    let palette: WidgetPalette
    let family: WidgetFamily
    var clock: Date? = nil

    var body: some View {
        if family == .systemSmall {
            NextClassSmallView(derived: derived, palette: palette)
        } else {
            NextClassMediumView(derived: derived, upNext: upNext, palette: palette, clock: clock)
        }
    }
}

struct NextClassMediumView: View {
    let derived: WidgetDerivedState
    let upNext: WidgetDerivedState.NextInfo?
    let palette: WidgetPalette
    /// Nil counts down on the device's clock, which WidgetKit keeps current between entries.
    let clock: Date?

    @ScaledMetric(relativeTo: .headline) private var nameSize: CGFloat = 17
    @ScaledMetric(relativeTo: .subheadline) private var rowNameSize: CGFloat = 15
    @ScaledMetric(relativeTo: .headline) private var blockHeight: CGFloat = 88

    var body: some View {
        Group {
            switch derived {
            case .signInRequired:
                TodayMessage(key: "widget_sign_in", palette: palette)
            case .noMoreClasses:
                Text(String(localized: "widget_no_more_classes"))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(palette.onSurface)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ongoing(let infos):
                let info = infos[0]
                layout(block(
                    course: info.course, room: info.classroom, change: info.change, start: info.startTime,
                    end: info.endTime, progress: info.progress
                ) { EmptyView() })
            case .nextToday(let info):
                layout(block(
                    course: info.course, room: info.classroom, change: info.change, start: info.startTime,
                    end: info.endTime, progress: nil
                ) { countdown(to: info.startTime) })
            case .tomorrowFirst(let info):
                layout(block(
                    course: info.course, room: info.classroom, change: info.change, start: info.startTime,
                    end: info.endTime, progress: nil
                ) { Text(info.day.headline()) })
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func layout(_ block: some View) -> some View {
        VStack(spacing: 8) {
            if let upNext {
                block.frame(height: blockHeight)
                row(upNext)
            } else {
                block
            }
        }
    }

    private func block(
        course: SnapshotCourse, room: String, change: SnapshotCourseChange?, start: String, end: String,
        progress: Double?, @ViewBuilder trailing: () -> some View
    ) -> some View {
        let tile = palette.tile(course.colorHex)
        let timeChanged = (change?.start ?? change?.end) != nil
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(course.displayName)
                    .font(.courseName(nameSize, weight: .bold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(TimeRange.text(start, end))
                    .accessibilityLabel(TimeRange.spoken(start, end))
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(timeChanged ? palette.changeInk : tile.secondaryInk)
                    .fixedSize()
                    .layoutPriority(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                WidgetRoom(
                    room: room, changed: change?.room != nil, font: .title.weight(.bold),
                    ink: tile.ink, changeInk: palette.changeInk
                )
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                trailing()
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 0)
            if let progress {
                ProgressCapsule(progress: progress, tile: tile)
            }
        }
        .foregroundStyle(tile.ink)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .classTile(tile, radius: 11, progress: progress, outline: 2, bottomBar: false)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func countdown(to start: String) -> some View {
        if let minutes = ClassTimeline.minutes(of: start),
           let startDate = TaipeiTime.calendar.date(
               byAdding: .minute, value: minutes, to: TaipeiTime.calendar.startOfDay(for: clock ?? AppClock.now())
           ) {
            if #available(iOS 18, macOS 15, *) {
                if let clock {
                    Text(clock, format: .reference(to: startDate))
                } else {
                    Text(.currentDate, format: .reference(to: startDate))
                }
            } else {
                Text(startDate, style: .relative)
            }
        }
    }

    private func row(_ info: WidgetDerivedState.NextInfo) -> some View {
        let tile = palette.tile(info.course.colorHex)
        let timeChanged = (info.change?.start ?? info.change?.end) != nil
        return HStack(spacing: 8) {
            NameRoomLine(
                name: info.course.displayName, room: info.classroom, roomChanged: info.change?.room != nil,
                nameFont: .courseName(rowNameSize, weight: .medium), roomFont: .headline.weight(.bold),
                ink: tile.ink, changeInk: palette.changeInk
            )
            Text(TimeRange.text(info.startTime, info.endTime))
                .accessibilityLabel(TimeRange.spoken(info.startTime, info.endTime))
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(timeChanged ? palette.changeInk : tile.secondaryInk)
                .fixedSize()
                .layoutPriority(1)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .classTile(tile, radius: 11, progress: nil, outline: 0, bottomBar: false)
        .accessibilityElement(children: .contain)
    }
}

struct NextClassSmallView: View {
    let derived: WidgetDerivedState
    let palette: WidgetPalette

    @ScaledMetric(relativeTo: .headline) private var nameSize: CGFloat = 17

    static func background(of derived: WidgetDerivedState, palette: WidgetPalette) -> Color {
        switch derived {
        case .ongoing(let infos): palette.isFullColor ? palette.tile(infos[0].course.colorHex).fill : .clear
        case .nextToday(let info), .tomorrowFirst(let info):
            palette.isFullColor ? palette.tile(info.course.colorHex).fill : .clear
        case .signInRequired, .noMoreClasses: palette.canvas
        }
    }

    var body: some View {
        Group {
            switch derived {
            case .signInRequired:
                TodayMessage(key: "widget_sign_in", palette: palette)
            case .noMoreClasses:
                Text(String(localized: "widget_no_more_classes"))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(palette.onSurface)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ongoing(let infos):
                let info = infos[0]
                let label = infos.count > 1 ? "\(String(localized: "widget_ongoing")) +\(infos.count - 1)" : String(localized: "widget_ongoing")
                card(
                    label: label, course: info.course, room: info.classroom, change: info.change,
                    start: info.startTime, end: info.endTime, progress: info.progress
                )
            case .nextToday(let info), .tomorrowFirst(let info):
                card(
                    label: info.day.headline(), course: info.course, room: info.classroom, change: info.change,
                    start: info.startTime, end: info.endTime, progress: nil
                )
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func card(
        label: String, course: SnapshotCourse, room: String, change: SnapshotCourseChange?,
        start: String, end: String, progress: Double?
    ) -> some View {
        let tile = palette.tile(course.colorHex)
        let timeChanged = (change?.start ?? change?.end) != nil
        return VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tile.secondaryInk)
                .lineLimit(1)
            Text(course.displayName)
                .font(.courseName(nameSize, weight: .bold))
                .foregroundStyle(tile.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .padding(.top, 2)
            WidgetRoom(
                room: room, changed: change?.room != nil, font: .title2.weight(.bold), ink: tile.ink,
                changeInk: palette.changeInk
            )
            .minimumScaleFactor(0.5)
            .layoutPriority(1)
            Spacer(minLength: 4)
            if let progress {
                ProgressCapsule(progress: progress, tile: tile)
                    .padding(.bottom, 4)
            }
            Text(end.isEmpty ? start : TimeRange.text(start, end))
                .accessibilityLabel(end.isEmpty ? start : TimeRange.spoken(start, end))
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(timeChanged ? palette.changeInk : tile.secondaryInk)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

/// A changed value with its small leading glyph, as the app's class table draws it.
struct ChangedValueLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}
