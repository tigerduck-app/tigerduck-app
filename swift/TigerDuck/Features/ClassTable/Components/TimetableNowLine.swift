import SwiftUI
import TigerDuckCore

/// The line across today's column at the current time, and where it crosses the rows.
struct TimetableNowLine: View {
    static let width: CGFloat = 1.5
    private static let dotSize: CGFloat = 7

    var body: some View {
        Rectangle()
            .fill(.tint)
            .frame(height: Self.width)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(.tint)
                    .frame(width: Self.dotSize, height: Self.dotSize)
                    .offset(x: -Self.dotSize / 2)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Where the current-time line crosses the rows, from the top of the first one: inside a period
    /// by the share of it gone, between two shown periods in the middle of their gap.
    nonisolated static func offset(
        minute: Int, periods: [(start: Int, end: Int)], rowPitch: CGFloat, cellHeight: CGFloat
    ) -> CGFloat? {
        for (index, period) in periods.enumerated() {
            let top = CGFloat(index) * rowPitch
            if minute < period.start { return index == 0 ? nil : top - (rowPitch - cellHeight) / 2 }
            if minute <= period.end {
                return top + cellHeight * CGFloat(minute - period.start) / CGFloat(max(1, period.end - period.start))
            }
        }
        return nil
    }

    static func minutes(_ period: TimetablePeriod) -> (start: Int, end: Int)? {
        func parse(_ time: String) -> Int? {
            let parts = time.split(separator: ":").compactMap { Int($0) }
            return parts.count == 2 ? parts[0] * 60 + parts[1] : nil
        }
        guard let start = parse(period.startTime), let end = parse(period.endTime) else { return nil }
        return (start, end)
    }

    static func minuteOfDay(_ date: Date) -> Int {
        let parts = TaipeiTime.calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}
