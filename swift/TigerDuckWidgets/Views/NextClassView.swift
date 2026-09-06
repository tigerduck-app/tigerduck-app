import SwiftUI
import WidgetKit

struct NextClassView: View {
    let derived: WidgetDerivedState
    let palette: WidgetPalette
    let family: WidgetFamily

    /// User-chosen multiplier for course-name font, read from the App
    /// Group at struct init. The main app reloads widget timelines after
    /// changing the value, so the next render picks up a fresh struct
    /// with the new scale.
    private let userScale: CGFloat = CGFloat(CourseCardFontScale.renderScale(CourseCardFontScaleStore().read()))

    /// Dynamic-Type-anchored baselines for the system fonts we replaced
    /// to multiply in `userScale`. `@ScaledMetric(relativeTo:)` makes
    /// the default Dynamic Type point size grow/shrink with the user's
    /// system text-size preference — so the surrounding `.subheadline`
    /// /  `.caption` / `.title3` labels (still semantic) and these
    /// course-name labels keep moving together as the user changes
    /// Display & Text Size. Without this, the course name would be a
    /// hard 15pt / 20pt / 12pt while neighbors continued to scale.
    @ScaledMetric(relativeTo: .subheadline) private var subheadlineBase: CGFloat = 15
    @ScaledMetric(relativeTo: .title3) private var title3Base: CGFloat = 20

    var body: some View {
        switch derived {
        case .signInRequired:
            signInBody
        case .ongoing(let infos):
            ongoingBody(infos: infos)
        case .nextToday(let info):
            nextBody(info: info)
        case .tomorrowFirst(let info):
            nextBody(info: info)
        case .noMoreClasses:
            emptyBody
        }
    }

    // MARK: - Variants

    private var isCompact: Bool { family == .systemSmall }

    private var signInBody: some View {
        Text(String(localized: "widget_sign_in"))
            .font(.callout)
            .foregroundStyle(palette.onSurfaceVariant)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func ongoingBody(infos: [WidgetDerivedState.OngoingInfo]) -> some View {
        if isCompact {
            // Compact: first ongoing only, with +N badge counting the rest.
            compactOngoing(first: infos[0], additionalCount: infos.count - 1)
        } else if infos.count >= 2 {
            VStack(spacing: 10) {
                ongoingCard(info: infos[0])
                ongoingCard(info: infos[1])
            }
        } else {
            ongoingCard(info: infos[0])
        }
    }

    private func compactOngoing(first info: WidgetDerivedState.OngoingInfo, additionalCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(String(localized: "widget_ongoing"))
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(palette.highlight, in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.white)
                if additionalCount > 0 {
                    Text("+\(additionalCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(palette.onSurfaceVariant)
                }
            }
            Text(info.course.displayName)
                .font(.system(size: subheadlineBase * userScale, weight: .bold))
                .foregroundStyle(palette.onSurface)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(String.localizedStringWithFormat(
                String(localized: "widget_until_time"), info.endTime))
                .font(.caption)
                .foregroundStyle(palette.onSurfaceVariant)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ongoingCard(info: WidgetDerivedState.OngoingInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "widget_ongoing"))
                .font(.caption.weight(.bold))
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(palette.highlight, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.white)
            Text(info.course.displayName)
                .font(.system(size: title3Base * userScale, weight: .bold))
                .foregroundStyle(palette.onSurface)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Text("\(info.startTime)–\(info.endTime)  \(info.periodRange)")
                .font(.caption)
                .foregroundStyle(palette.onSurfaceVariant)
            if !info.course.classroom.isEmpty {
                Text(info.course.classroom)
                    .font(.caption)
                    .foregroundStyle(palette.onSurfaceVariant)
            }
            Spacer(minLength: 4)
            ProgressView(value: info.progress)
                .progressViewStyle(.linear)
                .tint(palette.highlight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func nextBody(info: WidgetDerivedState.NextInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !isCompact {
                Text(info.day.headline)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(palette.onSurfaceVariant)
            }
            Text(info.course.displayName)
                .font(.system(
                    size: (isCompact ? subheadlineBase : title3Base) * userScale,
                    weight: .bold
                ))
                .foregroundStyle(palette.onSurface)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Text(info.startTime)
                .font(.caption)
                .foregroundStyle(palette.onSurfaceVariant)
            if !info.course.classroom.isEmpty {
                Text(info.course.classroom)
                    .font(.caption)
                    .foregroundStyle(palette.onSurfaceVariant)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyBody: some View {
        Text(String(localized: "widget_no_more_classes"))
            .font(.subheadline.weight(.bold))
            .foregroundStyle(palette.onSurface)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension WidgetDerivedState.Day {
    /// The caption above a next-class card. Mirrors Android's
    /// `NextClassContent.futureDayLabel`: "Tomorrow" only when the class
    /// literally is tomorrow, otherwise the weekday's own name, because the
    /// derivation scans up to a week ahead.
    var headline: String {
        switch self {
        case .today: return String(localized: "widget_next_class")
        case .tomorrow: return String(localized: "widget_tomorrow")
        case .later(let weekday): return Self.shortName(of: weekday)
        }
    }

    /// One-line form for the accessory families, which have no room for a
    /// separate caption row: "Tomorrow 09:10" against "Wed 09:10".
    func inlineCaption(_ trailing: String) -> String {
        switch self {
        case .later(let weekday):
            return "\(Self.shortName(of: weekday)) \(trailing)"
        case .today, .tomorrow:
            return String.localizedStringWithFormat(
                String(localized: "widget_tomorrow_time"), trailing)
        }
    }

    /// 1 = Monday … 7 = Sunday, matching `WidgetTimelineDerivation.weekdayFor`.
    private static func shortName(of weekday: Int) -> String {
        switch weekday {
        case 1: return String(localized: "weekday_mon_short")
        case 2: return String(localized: "weekday_tue_short")
        case 3: return String(localized: "weekday_wed_short")
        case 4: return String(localized: "weekday_thu_short")
        case 5: return String(localized: "weekday_fri_short")
        case 6: return String(localized: "weekday_sat_short")
        default: return String(localized: "weekday_sun_short")
        }
    }
}
