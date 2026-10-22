import SwiftUI

struct AvailabilityBar: View {
    let room: RoomUsage
    let period: Int
    let ended: Int

    var body: some View {
        let runs = freeRuns
        let period = period
        let count = CGFloat(EmptyClassroomSchedule.periodIDs.count)
        let track = Color.textPrimary.opacity(0.08)
        let needle = Color.textPrimary
        Canvas { context, size in
            let unit = size.width / count
            let height: CGFloat = 6
            let bar = CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
            context.fill(Capsule().path(in: bar), with: .color(track))
            for run in runs {
                let rect = CGRect(
                    x: unit * CGFloat(run.lowerBound), y: bar.minY,
                    width: unit * CGFloat(run.count), height: height
                )
                let color = run.contains(period) ? Color.green : Color.green.opacity(0.32)
                context.fill(Capsule().path(in: rect), with: .color(color))
            }
            let mark = CGRect(x: unit * CGFloat(period) - 1, y: 0, width: 2, height: size.height)
            context.fill(Capsule().path(in: mark), with: .color(needle))
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }

    private var freeRuns: [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        var index = max(ended, 0)
        while index < room.slots.count {
            guard let last = room.freeUntil(from: index) else {
                index += 1
                continue
            }
            runs.append(index...last)
            index = last + 1
        }
        return runs
    }
}

struct RoomAvailability: View {
    let room: RoomUsage
    let period: Int
    let ended: Int

    @ScaledMetric(relativeTo: .footnote) private var labelWidth: CGFloat = 44

    var body: some View {
        HStack(spacing: TigerDuckTheme.Spacing.md) {
            AvailabilityBar(room: room, period: period, ended: ended)
            Text(until)
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color.green)
                .lineLimit(1)
                .frame(minWidth: labelWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.freeSpanLabel(from: period, to: room.freeUntil(from: period) ?? period))
    }

    private var until: String {
        room.freeUntil(from: period).flatMap { EmptyClassroomSchedule.timeRange(of: $0)?.end } ?? ""
    }

    static func freeSpanLabel(from first: Int, to last: Int) -> String {
        String(
            format: String(localized: "a11y_empty_classroom_free_span"),
            EmptyClassroomSchedule.timeRange(of: first)?.start ?? "",
            EmptyClassroomSchedule.timeRange(of: last)?.end ?? ""
        )
    }
}

struct RoomRow: View {
    let room: RoomUsage
    let period: Int
    let ended: Int
    let policy: VisualStylePolicy
    let onRoom: (RoomUsage) -> Void

    var body: some View {
        HStack(spacing: TigerDuckTheme.Spacing.md) {
            Text(verbatim: "TR-000")
                .fixedSize()
                .hidden()
                .overlay(alignment: .leading) {
                    Text(room.room)
                        .foregroundStyle(policy.primaryTextColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .font(.headline)
                .monospacedDigit()
            RoomAvailability(room: room, period: period, ended: ended)
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.vertical, TigerDuckTheme.Spacing.md)
        .frame(minHeight: 50)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .scrollSafeTapAction { onRoom(room) }
    }
}
