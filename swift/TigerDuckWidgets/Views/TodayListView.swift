import SwiftUI
import WidgetKit

struct TodayListView: View {
    let snapshot: WidgetSnapshot
    let now: Date
    let palette: WidgetPalette
    let maxRows: Int

    /// User-chosen multiplier for course-name font, read from the App
    /// Group at struct init. The main app reloads widget timelines after
    /// changing the value, so the next render picks up the new scale.
    private let userScale: CGFloat = CGFloat(CourseCardFontScale.renderScale(CourseCardFontScaleStore().read()))

    /// Dynamic-Type-anchored baseline for the system `.caption` font.
    /// `@ScaledMetric(relativeTo:)` keeps the course-name label moving
    /// with the user's system text-size preference so the surrounding
    /// `.caption.weight(.bold)` / `.caption2` row metadata (still
    /// semantic) doesn't drift away from it under Accessibility text
    /// sizes.
    @ScaledMetric(relativeTo: .caption) private var captionBase: CGFloat = 12

    var body: some View {
        Group {
            if !snapshot.isLoggedIn {
                VStack {
                    Spacer()
                    Text(String(localized: "widget_sign_in"))
                        .font(.callout)
                        .foregroundStyle(palette.onSurfaceVariant)
                    Spacer()
                }
            } else {
                loggedInBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var loggedInBody: some View {
        let weekday = WidgetTimelineDerivation.weekdayFor(now)
        let isWeekend = weekday == 6 || weekday == 7
        let rows = WidgetTimelineDerivation.todayRows(snapshot: snapshot, at: now)
        let ongoing = ongoingBlocks(snapshot: snapshot, now: now)

        VStack(alignment: .leading, spacing: 6) {
            header(weekday: weekday)
            if rows.isEmpty {
                Spacer()
                Text(String(localized: isWeekend
                            ? "widget_no_classes_weekend"
                            : "widget_no_classes_today"))
                    .font(.callout)
                    .foregroundStyle(palette.onSurfaceVariant)
                Spacer()
            } else {
                ForEach(Array(rows.prefix(maxRows))) { todayRow in
                    let key = BlockKey(courseNo: todayRow.course.courseNo, startTime: todayRow.startTime)
                    row(todayRow, isOngoing: ongoing.contains(key))
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func header(weekday: Int) -> some View {
        let dayName = String(localized: String.LocalizationValue(weekdayKey(weekday)))
        let title = String.localizedStringWithFormat(
            String(localized: "widget_today_weekday_title"), dayName
        )
        return Text(title)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(palette.onSurface)
    }

    private func row(_ todayRow: WidgetTimelineDerivation.TodayRow, isOngoing: Bool) -> some View {
        let course = todayRow.course

        // The ongoing row uses the course color, not a token, so it branches on rendering mode
        // here. Outside `.fullColor` it takes the week grid's 0.25 wash (still reads as running,
        // no opaque slab) and palette label colors, since white only suited the saturated fill.
        let rowFill: Color
        let primary: Color
        let secondary: Color
        if isOngoing {
            let courseColor = Color(widgetHex: course.colorHex)
            rowFill = palette.isFullColor ? courseColor : courseColor.opacity(0.25)
            primary = palette.isFullColor ? .white : palette.onSurface
            secondary = palette.isFullColor
                ? Color.white.opacity(0.85)
                : palette.onSurfaceVariant
        } else {
            rowFill = palette.surface
            primary = palette.onSurface
            secondary = palette.onSurfaceVariant
        }

        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(todayRow.periodRange)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(primary)
                Text("\(todayRow.startTime)–\(todayRow.endTime)")
                    .font(.caption2)
                    .foregroundStyle(secondary)
            }
            .frame(width: 60, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(course.displayName)
                    .font(.system(size: captionBase * userScale, weight: .medium))
                    .foregroundStyle(primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !todayRow.classroom.isEmpty {
                    Text(todayRow.classroom)
                        .font(.caption2)
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(rowFill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func weekdayKey(_ weekday: Int) -> String {
        switch weekday {
        case 1: return "weekday_mon_short"
        case 2: return "weekday_tue_short"
        case 3: return "weekday_wed_short"
        case 4: return "weekday_thu_short"
        case 5: return "weekday_fri_short"
        case 6: return "weekday_sat_short"
        default: return "weekday_sun_short"
        }
    }

    /// A block by course and start time, so only the block in progress of a course that
    /// meets twice today is drawn as ongoing.
    private struct BlockKey: Hashable {
        let courseNo: String
        let startTime: String
    }

    private func ongoingBlocks(snapshot: WidgetSnapshot, now: Date) -> Set<BlockKey> {
        let derived = WidgetTimelineDerivation.derive(snapshot: snapshot, at: now)
        if case .ongoing(let infos) = derived {
            return Set(infos.map { BlockKey(courseNo: $0.course.courseNo, startTime: $0.startTime) })
        }
        return []
    }
}
