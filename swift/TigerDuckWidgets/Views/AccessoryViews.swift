import SwiftUI
import WidgetKit
import TigerDuckCore

/// An inline widget cuts its one line at the end, so the room goes before the name.
private func roomAndName(_ room: String, _ name: String) -> String {
    room.isEmpty ? name : "\(room) · \(name)"
}

struct AccessoryInlineView: View {
    let derived: WidgetDerivedState

    var body: some View {
        switch derived {
        case .signInRequired:
            Text(String(localized: "widget_sign_in"))
        case .ongoing(let infos):
            Text(roomAndName(infos[0].classroom, infos[0].course.displayName))
        case .nextToday(let info):
            Text("\(info.startTime) \(roomAndName(info.classroom, info.course.displayName))")
        case .tomorrowFirst(let info):
            Text(info.day.inlineCaption("\(info.startTime) \(roomAndName(info.classroom, info.course.displayName))"))
        case .noMoreClasses:
            Text(String(localized: "widget_no_more_classes"))
        }
    }
}

struct AccessoryCircularView: View {
    let derived: WidgetDerivedState

    var body: some View {
        switch derived {
        case .ongoing(let infos):
            let info = infos[0]
            Gauge(value: info.progress) {
                EmptyView()
            } currentValueLabel: {
                label(top: info.classroom.isEmpty ? String(info.course.displayName.prefix(3)) : info.classroom, bottom: info.endTime)
            }
            .gaugeStyle(.accessoryCircularCapacity)
        case .nextToday(let info), .tomorrowFirst(let info):
            label(top: info.classroom.isEmpty ? String(info.course.displayName.prefix(3)) : info.classroom, bottom: info.startTime)
        case .signInRequired, .noMoreClasses:
            Image(systemName: "calendar")
        }
    }

    private func label(top: String, bottom: String) -> some View {
        VStack(spacing: 0) {
            Text(top)
                .font(.system(size: 12, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(bottom)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
        }
        .padding(.horizontal, 4)
    }
}

struct AccessoryRectangularView: View {
    let derived: WidgetDerivedState

    var body: some View {
        switch derived {
        case .signInRequired:
            Text(String(localized: "widget_sign_in"))
        case .ongoing(let infos):
            let info = infos[0]
            VStack(alignment: .leading, spacing: 2) {
                Text(info.course.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(info.classroom)
                    .font(.footnote.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                ProgressView(value: info.progress)
                    .progressViewStyle(.linear)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .nextToday(let info), .tomorrowFirst(let info):
            VStack(alignment: .leading, spacing: 1) {
                Text(info.day.headline())
                    .font(.caption2.weight(.bold))
                Text(info.course.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(info.startTime).monospacedDigit()
                    Text(info.classroom)
                        .fontWeight(.bold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .font(.caption2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .noMoreClasses:
            Text(String(localized: "widget_no_more_classes"))
                .font(.caption)
        }
    }
}
