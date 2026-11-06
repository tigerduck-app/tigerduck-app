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
                    Self.timer(real)
                        .multilineTextAlignment(.trailing)
                }
                .font(.footnote.weight(.semibold).monospacedDigit())
        }
    }

    static func timer(_ real: ClosedRange<Date>, pausedAt pause: Date? = nil) -> Text {
        Text(timerInterval: real, pauseTime: pause, countsDown: true, showsHours: true)
    }

    var widest: String {
        let seconds = Int(span.upperBound.timeIntervalSince(span.lowerBound))
        func zeros(_ value: Int) -> String { String(repeating: "0", count: String(value).count) }
        return seconds >= 3_600 ? zeros(seconds / 3_600) + ":00:00" : zeros(seconds / 60) + ":00"
    }
}

extension WatchCourse {
    var color: Color { Color(hex: colorHex) ?? .accentColor }
}
