import SwiftUI

/// A room's day as a thin track over the 14 periods: its free runs as capsules, the run holding
/// the chosen period solid, and a needle at that period's start. Periods already over are not
/// drawn as free.
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

/// The bar with the end of the room's free run beside it, read by VoiceOver as the free span.
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

/// How to get from one room to the next: a pin for staying, stairs with the floors, or a walk
/// with its minutes.
struct MovementBadge: View {
    let move: RoomMove

    var body: some View {
        HStack(spacing: TigerDuckTheme.Spacing.xs) {
            Image(systemName: symbol)
                .imageScale(.small)
            if let text {
                Text(text)
                    .monospacedDigit()
            }
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(Color.textPrimary.opacity(0.85))
        .padding(.horizontal, TigerDuckTheme.Spacing.sm)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.textPrimary.opacity(0.1)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var symbol: String {
        switch move {
        case .sameRoom: "mappin"
        case .floors: "figure.stairs"
        case .walk: "figure.walk"
        }
    }

    private var text: String? {
        switch move {
        case .sameRoom: nil
        case .floors(let floors): "\(floors > 0 ? "↑" : "↓")\(abs(floors))"
        case .walk(let minutes): String(format: String(localized: "empty_classroom_walk_minutes"), minutes)
        }
    }

    private var label: String {
        switch move {
        case .sameRoom:
            String(localized: "a11y_empty_classroom_same_room")
        case .floors(let floors) where floors > 0:
            String(format: String(localized: "a11y_empty_classroom_floors_up"), floors)
        case .floors(let floors):
            String(format: String(localized: "a11y_empty_classroom_floors_down"), -floors)
        case .walk(let minutes):
            String(format: String(localized: "a11y_empty_classroom_walk_minutes"), minutes)
        }
    }
}
