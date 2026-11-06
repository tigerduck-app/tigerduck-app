import SwiftUI
import WidgetKit

/// The system advances both views without a timeline reload:
/// https://developer.apple.com/documentation/widgetkit/displaying-dynamic-dates
struct ClassCountdown: View {
    let span: ClosedRange<Date>
    let tint: Color

    var body: some View {
        let real = AppClock.realTime(forApp: span)
        HStack(spacing: 8) {
            ProgressView(timerInterval: real, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .tint(tint)
            .widgetAccentable()
            // In a widget, timer text fills the width it is offered, so a hidden copy of its widest
            // value sizes it: https://developer.apple.com/documentation/swiftui/text/init(timerinterval:pausetime:countsdown:showshours:)
            Text(widest)
                .hidden()
                .overlay(alignment: .trailing) {
                    Text(timerInterval: real, countsDown: true, showsHours: false)
                        .multilineTextAlignment(.trailing)
                }
                .font(.footnote.weight(.semibold).monospacedDigit())
        }
    }

    var widest: String {
        let minutes = Int(span.upperBound.timeIntervalSince(span.lowerBound) / 60)
        return String(repeating: "0", count: String(minutes).count) + ":00"
    }
}

extension WatchCourse {
    var color: Color { Color(hex: colorHex) ?? .accentColor }
}
