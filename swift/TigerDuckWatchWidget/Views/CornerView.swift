import SwiftUI
import WidgetKit
import TigerDuckCore

struct CornerView: View {
    let entry: NextClassEntry

    var body: some View {
        Text(label)
            .minimumScaleFactor(0.5)
            .widgetAccentable()
            .widgetCurvesContent()
            .containerBackground(.fill.tertiary, for: .widget)
            .widgetLabel {
                if let span = entry.currentSpan, let course = entry.current {
                    ProgressView(timerInterval: AppClock.realTime(forApp: span), countsDown: false) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                    .tint(course.color)
                    .widgetAccentable()
                } else {
                    Text(timeText)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entry.spokenSummary)
    }

    var label: String {
        (entry.current ?? entry.next)?.roomOrName ?? "—"
    }
    var timeText: String {
        if let c = entry.current { return c.endHHmm }
        if let n = entry.next { return entry.nextDay.inlineCaption(n.startHHmm, in: entry.language) }
        return ""
    }
}
