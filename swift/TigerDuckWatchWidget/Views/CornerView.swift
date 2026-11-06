import SwiftUI
import WidgetKit
import TigerDuckCore

struct CornerView: View {
    let entry: NextClassEntry

    var body: some View {
        Text(label)
            .minimumScaleFactor(0.5)
            .widgetCurvesContent()
            .containerBackground(.fill.tertiary, for: .widget)
            .widgetLabel {
                if let span = entry.currentSpan, let course = entry.current {
                    ProgressView(timerInterval: span.onRealClock, countsDown: false) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                    .tint(course.color)
                } else {
                    Text(timeText)
                }
            }
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
