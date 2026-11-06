import SwiftUI
import TigerDuckCore
import WidgetKit

extension Font {
    static func courseName(_ size: CGFloat, weight: Font.Weight) -> Font {
        .system(size: size * CGFloat(CourseCardFontScale.renderScale(CourseCardFontScaleStore().read())), weight: weight)
    }
}

extension WidgetFamily {
    var isExtraLargePortrait: Bool {
        #if compiler(>=6.4)
        if #available(iOS 27, macOS 27, *) { return self == .systemExtraLargePortrait }
        #endif
        return false
    }

    static func withExtraLargePortrait(_ families: [WidgetFamily]) -> [WidgetFamily] {
        #if compiler(>=6.4)
        if #available(iOS 27, macOS 27, *) { return families + [.systemExtraLargePortrait] }
        #endif
        return families
    }
}

struct NameRoomLine: View {
    let name: String
    let room: String
    var roomChanged = false
    var isCancelled = false
    let nameFont: Font
    let roomFont: Font
    let ink: Color
    let changeInk: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
                .font(nameFont)
                .strikethrough(isCancelled)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
            WidgetRoom(room: room, changed: roomChanged, font: roomFont, ink: ink, changeInk: changeInk)
                .fixedSize()
                .layoutPriority(1)
        }
        .foregroundStyle(ink)
    }
}

struct WidgetRoom: View {
    let room: String
    var changed = false
    let font: Font
    let ink: Color
    let changeInk: Color

    var body: some View {
        if changed {
            Label(room, systemImage: "arrow.left.arrow.right")
                .labelStyle(ChangedValueLabelStyle())
                .font(font)
                .foregroundStyle(changeInk)
                .lineLimit(1)
        } else if !room.isEmpty {
            Text(room)
                .font(font)
                .foregroundStyle(ink)
                .lineLimit(1)
        }
    }
}

struct ProgressCapsule: View {
    let progress: Double
    let tile: WidgetTile
    var height: CGFloat = 4

    var body: some View {
        Capsule()
            .fill(tile.track)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(tile.accent)
                        .frame(width: geometry.size.width * min(max(progress, 0), 1))
                }
            }
            .frame(height: height)
            .accessibilityHidden(true)
    }
}

extension View {
    func classTile(_ tile: WidgetTile, radius: CGFloat, progress: Double?, outline: CGFloat, bottomBar: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(tile.fill, in: shape)
            .overlay {
                if progress != nil { shape.strokeBorder(tile.accent, lineWidth: outline) }
            }
            .overlay(alignment: .bottomLeading) {
                if bottomBar, let progress {
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(tile.accent)
                            .frame(width: geometry.size.width * min(max(progress, 0), 1), height: 3)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    .accessibilityHidden(true)
                }
            }
            .clipShape(shape)
    }
}

struct WidgetDayHeader: View {
    let day: Date
    var title: String? = nil
    let titleFont: Font
    let dateFont: Font
    let palette: WidgetPalette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title ?? Self.weekdayTitle(of: day))
                .font(titleFont)
                .foregroundStyle(palette.onSurface)
            Text(day.formatted(Self.dateStyle))
                .font(dateFont)
                .foregroundStyle(palette.onSurfaceVariant)
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    static func weekdayTitle(of day: Date) -> String {
        String.localizedStringWithFormat(
            String(localized: "widget_today_weekday_title"), String(localized: weekdayKey(ClassTimeline.weekday(of: day)))
        )
    }

    static func weekdayKey(_ weekday: Int) -> LocalizedStringResource {
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

    /// Widgets take the app's language, which can differ from the region the date would follow.
    private static var dateStyle: Date.FormatStyle {
        Date.FormatStyle(
            locale: Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en"), timeZone: TaipeiTime.timeZone
        )
        .month(.abbreviated)
        .day()
    }
}
