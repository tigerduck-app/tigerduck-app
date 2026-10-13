import SwiftUI

/// The suggested room, with the way there from the class before and on to the class after, and
/// the next two rooms in a grouped card under it. No header: its place on the screen says it.
struct SuggestionSection: View {
    let suggestion: RoomSuggestion
    let ended: Int
    let policy: VisualStylePolicy
    let place: (RoomUsage) -> String
    let onRoom: (RoomUsage) -> Void

    @ScaledMetric(relativeTo: .subheadline) private var railWidth: CGFloat = 20
    @ScaledMetric(relativeTo: .footnote) private var timeWidth: CGFloat = 42

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
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.md) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: TigerDuckTheme.Spacing.md) {
                    roomTitle(best)
                    Spacer(minLength: 0)
                    placeLabel(best)
                }
                VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
                    roomTitle(best)
                    placeLabel(best)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                if let previous = suggestion.previous {
                    classRow(previous, time: EmptyClassroomSchedule.timeRange(of: previous.lastPeriod)?.end)
                    moveRow(RoomMove.between(previous.place, best.place))
                }
                freeRow(suggestion.freeSpan(of: best))
                if let next = suggestion.next {
                    moveRow(RoomMove.between(best.place, next.place))
                    classRow(next, time: EmptyClassroomSchedule.timeRange(of: next.firstPeriod)?.start)
                }
            }
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

    private func placeLabel(_ candidate: RoomSuggestion.Candidate) -> some View {
        Label(place(candidate.room), systemImage: "building.2")
            .font(.subheadline)
            .foregroundStyle(policy.secondaryTextColor)
            .lineLimit(1)
    }

    private func classRow(_ stop: ClassStop, time: String?) -> some View {
        HStack(spacing: TigerDuckTheme.Spacing.sm) {
            Circle()
                .strokeBorder(policy.secondaryTextColor, lineWidth: 2)
                .frame(width: 10, height: 10)
                .frame(width: railWidth)
            Text(time ?? "")
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: timeWidth, alignment: .leading)
            Text(stop.course)
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: TigerDuckTheme.Spacing.xs)
            Text(stop.room)
                .font(.subheadline)
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(policy.secondaryTextColor)
        .frame(minHeight: 26)
    }

    private func moveRow(_ move: RoomMove?) -> some View {
        HStack(spacing: TigerDuckTheme.Spacing.sm) {
            Capsule()
                .fill(policy.secondaryTextColor.opacity(0.4))
                .frame(width: 2)
                .frame(width: railWidth)
            if let move {
                MovementBadge(move: move)
            }
        }
        .frame(minHeight: 24, alignment: .leading)
    }

    private func freeRow(_ span: ClosedRange<Int>) -> some View {
        HStack(spacing: TigerDuckTheme.Spacing.sm) {
            Circle()
                .fill(Color.green)
                .frame(width: 14, height: 14)
                .background(Circle().fill(Color.green.opacity(0.2)).padding(-4))
                .frame(width: railWidth)
            HStack(spacing: TigerDuckTheme.Spacing.sm) {
                Text(EmptyClassroomSchedule.timeRange(of: span.lowerBound)?.start ?? "")
                Capsule()
                    .fill(Color.green.opacity(0.45))
                    .frame(height: 2)
                Text(EmptyClassroomSchedule.timeRange(of: span.upperBound)?.end ?? "")
            }
            .font(.subheadline.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(Color.green)
            .padding(.horizontal, TigerDuckTheme.Spacing.md)
            .padding(.vertical, TigerDuckTheme.Spacing.sm)
            .background(Capsule().fill(Color.green.opacity(0.18)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(RoomAvailability.freeSpanLabel(from: span.lowerBound, to: span.upperBound))
        }
    }

    // MARK: - The next two

    private func alternatives(_ candidates: [RoomSuggestion.Candidate]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(candidates.enumerated()), id: \.element.room.id) { index, candidate in
                if index > 0 {
                    Divider().padding(.leading, TigerDuckTheme.Spacing.lg)
                }
                alternativeRow(candidate)
            }
        }
        .presetCard(policy: policy)
    }

    private func alternativeRow(_ candidate: RoomSuggestion.Candidate) -> some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            HStack(spacing: TigerDuckTheme.Spacing.sm) {
                Text(candidate.room.room)
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(policy.primaryTextColor)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(place(candidate.room))
                    .font(.footnote)
                    .foregroundStyle(policy.secondaryTextColor)
                    .lineLimit(1)
                Spacer(minLength: TigerDuckTheme.Spacing.xs)
                if let move = suggestion.move(to: candidate) {
                    MovementBadge(move: move)
                        .layoutPriority(1)
                }
            }
            RoomAvailability(room: candidate.room, period: suggestion.period, ended: ended)
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.vertical, TigerDuckTheme.Spacing.md)
        .scrollSafeTapAction { onRoom(candidate.room) }
    }
}
