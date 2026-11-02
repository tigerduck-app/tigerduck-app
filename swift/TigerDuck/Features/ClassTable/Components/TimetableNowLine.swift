import SwiftUI
import TigerDuckCore

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

    /// Nil before the first period and after the last.
    nonisolated static func offset(
        minute: Int, periods: [(start: Int, end: Int)], rowPitch: CGFloat, cellHeight: CGFloat
    ) -> CGFloat? {
        guard let first = periods.first, let last = periods.last, (first.start...last.end).contains(minute) else { return nil }
        return position(minute: minute, periods: periods, rowPitch: rowPitch, cellHeight: cellHeight)
    }

    /// A period's share of its row, and the time between two periods the same share of the gap
    /// between their rows; held to the first row's top and the last row's bottom.
    nonisolated static func position(
        minute: Int, periods: [(start: Int, end: Int)], rowPitch: CGFloat, cellHeight: CGFloat
    ) -> CGFloat {
        func share(_ minute: Int, from start: Int, to end: Int) -> CGFloat {
            CGFloat(minute - start) / CGFloat(max(1, end - start))
        }
        var previousEnd: Int?
        for (index, period) in periods.enumerated() {
            let top = CGFloat(index) * rowPitch
            if minute < period.start {
                guard let previousEnd else { return 0 }
                let gap = rowPitch - cellHeight
                return top - gap + gap * share(minute, from: previousEnd, to: period.start)
            }
            if minute <= period.end { return top + cellHeight * share(minute, from: period.start, to: period.end) }
            previousEnd = period.end
        }
        return periods.isEmpty ? 0 : CGFloat(periods.count - 1) * rowPitch + cellHeight
    }

    static func minuteOfDay(_ date: Date) -> Int {
        let parts = TaipeiTime.calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}
