import SwiftUI

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
        (entry.next ?? entry.current)?.name ?? "—"
    }
    private var timeText: String {
        if let c = entry.current { return c.endHHmm }
        if let n = entry.next { return n.startHHmm }
        return ""
    }
}
