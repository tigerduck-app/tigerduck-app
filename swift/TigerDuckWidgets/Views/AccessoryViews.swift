import SwiftUI
import WidgetKit

struct AccessoryInlineView: View {
    let derived: WidgetDerivedState

    var body: some View {
        switch derived {
        case .signInRequired:
            Text(String(localized: "widget_sign_in"))
        case .ongoing(let infos):
            Text("\(String(localized: "widget_ongoing")): \(infos[0].course.displayName)")
        case .nextToday(let info):
            Text("\(String(localized: "widget_next_class_short")): \(info.course.displayName) · \(info.startTime)")
        case .tomorrowFirst(let info):
            Text(String.localizedStringWithFormat(
                String(localized: "widget_tomorrow_time"),
                "\(info.course.displayName) \(info.startTime)"
            ))
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
            VStack(spacing: 0) {
                Text(String(info.course.displayName.prefix(3)))
                    .font(.system(size: 12, weight: .bold))
                Text(info.endTime)
                    .font(.system(size: 8))
            }
        case .nextToday(let info):
            VStack(spacing: 0) {
                Text(String(info.course.displayName.prefix(3)))
                    .font(.system(size: 12, weight: .bold))
                Text(info.startTime)
                    .font(.system(size: 8))
            }
        case .tomorrowFirst(let info):
            VStack(spacing: 0) {
                Text(String(info.course.displayName.prefix(3)))
                    .font(.system(size: 12, weight: .bold))
                Text(info.startTime)
                    .font(.system(size: 8))
            }
        case .signInRequired, .noMoreClasses:
            Image(systemName: "calendar")
        }
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
            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "widget_ongoing"))
                    .font(.caption2.weight(.bold))
                Text(info.course.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text("\(info.startTime)–\(info.endTime)").font(.caption2)
                    if !info.course.classroom.isEmpty {
                        Text("·").font(.caption2)
                        Text(info.course.classroom).font(.caption2)
                    }
                }
            }
        case .nextToday(let info):
            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "widget_next_class"))
                    .font(.caption2.weight(.bold))
                Text(info.course.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("\(info.startTime)  \(info.course.classroom)")
                    .font(.caption2)
            }
        case .tomorrowFirst(let info):
            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "widget_tomorrow"))
                    .font(.caption2.weight(.bold))
                Text(info.course.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(info.startTime)
                    .font(.caption2)
            }
        case .noMoreClasses:
            Text(String(localized: "widget_no_more_classes"))
                .font(.caption)
        }
    }
}
