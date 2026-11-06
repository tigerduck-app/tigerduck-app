import SwiftUI
import WidgetKit

struct CircularView: View {
    let entry: NextClassEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let span = entry.currentSpan, let course = entry.current {
                ProgressView(timerInterval: AppClock.realTime(forApp: span), countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .progressViewStyle(.circular)
                .tint(course.color)
                .widgetAccentable()
            }
            Text(label)
                .font(.caption2.bold())
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 6)
                .widgetAccentable()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.spokenSummary)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    var label: String {
        (entry.current ?? entry.next)?.roomOrName ?? "—"
    }
}
