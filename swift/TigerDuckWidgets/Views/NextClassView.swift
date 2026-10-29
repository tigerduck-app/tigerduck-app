import SwiftUI
import WidgetKit

struct NextClassView: View {
    let derived: WidgetDerivedState
    let palette: WidgetPalette
    let family: WidgetFamily

    private let userScale: CGFloat = CGFloat(CourseCardFontScale.renderScale(CourseCardFontScaleStore().read()))

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
                .foregroundStyle(info.change?.end != nil ? palette.changeInk : palette.onSurfaceVariant)
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
                .foregroundStyle(info.change?.start ?? info.change?.end != nil ? palette.changeInk : palette.onSurfaceVariant)
            room(info.classroom, changed: info.change?.room != nil)
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
                .foregroundStyle(info.change?.start != nil ? palette.changeInk : palette.onSurfaceVariant)
            room(info.classroom, changed: info.change?.room != nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func room(_ room: String, changed: Bool) -> some View {
        if changed {
            Label(room, systemImage: "arrow.left.arrow.right")
                .labelStyle(ChangedValueLabelStyle())
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.changeInk)
                .lineLimit(1)
        } else if !room.isEmpty {
            Text(room)
                .font(.caption)
                .foregroundStyle(palette.onSurfaceVariant)
        }
    }

    private var emptyBody: some View {
        Text(String(localized: "widget_no_more_classes"))
            .font(.subheadline.weight(.bold))
            .foregroundStyle(palette.onSurface)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

extension WidgetDerivedState.Day {
    var headline: String {
        switch self {
        case .today: return String(localized: "widget_next_class")
        case .tomorrow: return String(localized: "widget_tomorrow")
        case .later(let weekday): return Self.caption(of: weekday)
        }
    }

    func inlineCaption(_ trailing: String) -> String {
        switch self {
        case .later(let weekday):
            return "\(Self.caption(of: weekday)) \(trailing)"
        case .today, .tomorrow:
            return String.localizedStringWithFormat(
                String(localized: "widget_tomorrow_time"), trailing)
        }
    }

    private static func caption(of weekday: Int) -> String {
        switch weekday {
        case 1: return String(localized: "weekday_mon_caption")
        case 2: return String(localized: "weekday_tue_caption")
        case 3: return String(localized: "weekday_wed_caption")
        case 4: return String(localized: "weekday_thu_caption")
        case 5: return String(localized: "weekday_fri_caption")
        case 6: return String(localized: "weekday_sat_caption")
        default: return String(localized: "weekday_sun_caption")
        }
    }
}
