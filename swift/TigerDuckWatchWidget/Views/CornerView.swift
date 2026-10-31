import SwiftUI
import WidgetKit
import TigerDuckCore

struct CornerView: View {
    let entry: NextClassEntry

    var body: some View {
        Text(label)
            .widgetCurvesContent()
            .containerBackground(.fill.tertiary, for: .widget)
            .widgetLabel {
                Text(timeText)
            }
    }

    private var label: String {
        (entry.current ?? entry.next)?.name ?? "—"
    }
    var timeText: String {
        if let c = entry.current { return c.endHHmm }
        if let n = entry.next { return entry.nextDay.inlineCaption(n.startHHmm, in: entry.language) }
        return ""
    }
}
