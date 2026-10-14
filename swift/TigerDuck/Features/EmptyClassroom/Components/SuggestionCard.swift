import SwiftUI

/// The suggested room, its free time and the way there from the class before and on to the class
/// after, and the next two rooms in a grouped card under it. No header: its place on the screen
/// says it.
struct SuggestionSection: View {
    let suggestion: RoomSuggestion
    let ended: Int
    let policy: VisualStylePolicy
    let onRoom: (RoomUsage) -> Void

    var body: some View {
        VStack(spacing: TigerDuckTheme.Spacing.sm) {
            if let best = suggestion.candidates.first {
                card(best)
            }
            let others = Array(suggestion.candidates.dropFirst())
            if !others.isEmpty {
                alternatives(others)
            }
        }
    }

    // MARK: - The suggested room

    private func card(_ best: RoomSuggestion.Candidate) -> some View {
        let span = suggestion.freeSpan(of: best)
        return VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.lg) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: TigerDuckTheme.Spacing.md) {
                    roomTitle(best)
                    Spacer(minLength: 0)
                    freeSpan(span)
                }
                VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
                    roomTitle(best)
                    freeSpan(span)
                }
            }
            RouteLine(previous: suggestion.previous, room: best.place, next: suggestion.next, policy: policy)
        }
        .padding(TigerDuckTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presetCard(policy: policy, cornerRadius: TigerDuckTheme.CornerRadius.xl)
        .scrollSafeTapAction { onRoom(best.room) }
    }

    private func roomTitle(_ candidate: RoomSuggestion.Candidate) -> some View {
        Text(candidate.room.room)
            .font(.largeTitle.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(policy.primaryTextColor)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private func freeSpan(_ span: ClosedRange<Int>) -> some View {
        let start = EmptyClassroomSchedule.timeRange(of: span.lowerBound)?.start ?? ""
        let end = EmptyClassroomSchedule.timeRange(of: span.upperBound)?.end ?? ""
        return Text("\(start)–\(end)")
            .font(.headline)
            .monospacedDigit()
            .foregroundStyle(Color.green)
            .lineLimit(1)
            .accessibilityLabel(RoomAvailability.freeSpanLabel(from: span.lowerBound, to: span.upperBound))
    }

    // MARK: - The next two

    private func alternatives(_ candidates: [RoomSuggestion.Candidate]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(candidates.enumerated()), id: \.element.room.id) { index, candidate in
                if index > 0 {
                    Divider().padding(.leading, TigerDuckTheme.Spacing.lg)
                }
                RoomRow(room: candidate.room, period: suggestion.period, ended: ended, policy: policy, onRoom: onRoom)
            }
        }
        .presetCard(policy: policy)
    }
}

/// The class before as a ring, the room as the green dot and the class after as a ring, with the
/// classes' rooms under the ends. A leg shows stairs or a walk only when it takes one: staying in
/// the room or crossing a floor is a bare line, and VoiceOver still names the move.
struct RouteLine: View {
    let previous: ClassStop?
    let room: RoomPlace?
    let next: ClassStop?
    let policy: VisualStylePolicy

    var body: some View {
        VStack(spacing: TigerDuckTheme.Spacing.xs) {
            HStack(spacing: 0) {
                if let previous {
                    classStop
                    leg(RoomMove.between(previous.place, room))
                }
                roomStop
                if let next {
                    leg(RoomMove.between(room, next.place))
                    classStop
                }
            }
            .frame(minHeight: 20)
            HStack(spacing: TigerDuckTheme.Spacing.md) {
                Text(previous?.room ?? "")
                Spacer(minLength: 0)
                Text(next?.room ?? "")
            }
            .font(.footnote)
            .monospacedDigit()
            .foregroundStyle(policy.secondaryTextColor)
            .lineLimit(1)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var classStop: some View {
        Circle()
            .strokeBorder(policy.secondaryTextColor, lineWidth: 2)
            .frame(width: 10, height: 10)
    }

    private var roomStop: some View {
        Circle()
            .fill(Color.green)
            .frame(width: 14, height: 14)
            .background(Circle().fill(Color.green.opacity(0.2)).padding(-4))
    }

    private func leg(_ move: RoomMove?) -> some View {
        let isWalk = if case .walk = move { true } else { false }
        return HStack(spacing: TigerDuckTheme.Spacing.xs) {
            track(dotted: isWalk)
            if let move, let symbol = move.symbol {
                HStack(spacing: 3) {
                    Image(systemName: symbol)
                        .imageScale(.small)
                    Text(move.text ?? "")
                        .monospacedDigit()
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(policy.primaryTextColor.opacity(0.85))
                .lineLimit(1)
                .fixedSize()
                track(dotted: isWalk)
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.sm)
        .frame(maxWidth: .infinity)
    }

    /// Dotted for a walk, as maps draw one.
    private func track(dotted: Bool) -> some View {
        TrackShape()
            .stroke(
                policy.secondaryTextColor.opacity(dotted ? 0.7 : 0.4),
                style: dotted
                    ? StrokeStyle(lineWidth: 3, lineCap: .round, dash: [0, 6])
                    : StrokeStyle(lineWidth: 2, lineCap: .round)
            )
            .frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: 4)
    }

    private var accessibilityText: String {
        let into = previous.flatMap { RoomMove.between($0.place, room) }
        let onward = next.flatMap { RoomMove.between(room, $0.place) }
        return [previous?.room, into?.accessibilityLabel, onward?.accessibilityLabel, next?.room]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

private struct TrackShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

extension RoomMove {
    /// Nil for staying in the room, which needs no sign.
    var symbol: String? {
        switch self {
        case .sameRoom: nil
        case .floors: "figure.stairs"
        case .walk: "figure.walk"
        }
    }

    var text: String? {
        switch self {
        case .sameRoom: nil
        case .floors(let floors): "\(floors > 0 ? "↑" : "↓")\(abs(floors))"
        case .walk(let minutes): String(format: String(localized: "empty_classroom_walk_minutes"), minutes)
        }
    }

    var accessibilityLabel: String {
        switch self {
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
