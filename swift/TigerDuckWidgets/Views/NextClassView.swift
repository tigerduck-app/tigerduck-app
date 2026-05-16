import SwiftUI
import WidgetKit

struct NextClassView: View {
    let derived: WidgetDerivedState
    let palette: WidgetPalette
    let family: WidgetFamily

    var body: some View {
        switch derived {
        case .signInRequired:
            signInBody
        case .ongoing(let infos):
            ongoingBody(infos: infos)
        case .nextToday(let info):
            nextBody(info: info, kind: .nextToday)
        case .tomorrowFirst(let info):
            nextBody(info: info, kind: .tomorrow)
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
                .font(.subheadline.weight(.bold))
                .foregroundStyle(palette.onSurface)
                .lineLimit(1)
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
                .font(.title3.weight(.bold))
                .foregroundStyle(palette.onSurface)
                .lineLimit(2)
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

    private enum NextKind { case nextToday, tomorrow }

    private func nextBody(info: WidgetDerivedState.NextInfo, kind: NextKind) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !isCompact {
                Text(kind == .nextToday
                     ? String(localized: "widget_next_class")
                     : String(localized: "widget_tomorrow"))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(palette.onSurfaceVariant)
            }
            Text(info.course.displayName)
                .font(isCompact ? .subheadline.weight(.bold) : .title3.weight(.bold))
                .foregroundStyle(palette.onSurface)
                .lineLimit(2)
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
