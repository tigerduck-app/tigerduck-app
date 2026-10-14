import SwiftUI

/// A room's day, period by period: a lane green while free and orange while booked, joined
/// across neighbouring periods, and each class with its teacher. A booking shows no name.
struct RoomDaySheet: View {
    let room: RoomUsage
    /// The building's name and the room's floor.
    let place: String
    let day: String
    let period: Int
    let ended: Int
    /// The period in progress, or the next in a break, which today's now line marks; nil on
    /// another day and after the last period.
    let nowPeriod: Int?
    let policy: VisualStylePolicy

    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .caption) private var timeWidth: CGFloat = 84
    @ScaledMetric(relativeTo: .subheadline) private var labelWidth: CGFloat = 24
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 40
    @ScaledMetric(relativeTo: .body) private var closeSize: CGFloat = 34

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.lg) {
                header
                VStack(spacing: 0) {
                    ForEach(EmptyClassroomSchedule.periodIDs.indices, id: \.self) { index in
                        row(index)
                    }
                }
                .padding(.vertical, TigerDuckTheme.Spacing.sm)
                .presetCard(policy: policy)
                legend
            }
            .padding(TigerDuckTheme.Spacing.lg)
        }
        .scrollIndicators(.hidden)
        .background(Color.backgroundPrimary)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: TigerDuckTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
                Text(room.room)
                    .font(.largeTitle.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(policy.primaryTextColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Label([place, day].joined(separator: " · "), systemImage: "building.2")
                    .font(.subheadline)
                    .foregroundStyle(policy.secondaryTextColor)
            }
            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(policy.secondaryTextColor)
                    .frame(width: closeSize, height: closeSize)
                    .background(Circle().fill(Color.textPrimary.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "action_close"))
        }
    }

    private func row(_ index: Int) -> some View {
        let id = EmptyClassroomSchedule.periodIDs[index]
        let isSelected = index == period
        let spacing = TigerDuckTheme.Spacing.md
        return HStack(spacing: spacing) {
            Text(id)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(policy.primaryTextColor))
                .frame(width: labelWidth)
            Text(EmptyClassroomViewModel.timeRange(of: index))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(policy.secondaryTextColor)
                .frame(width: timeWidth, alignment: .leading)
            Color.clear.frame(width: Self.laneWidth)
            use(index)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.horizontal, spacing)
        .frame(minHeight: rowHeight)
        // In the background, the lane spans the whole row and meets the next row's.
        .background(alignment: .leading) {
            ZStack(alignment: .leading) {
                if isSelected {
                    Rectangle().fill(.tint.opacity(0.16))
                }
                lane(index)
                    .padding(.leading, spacing + labelWidth + spacing + timeWidth + spacing)
            }
        }
        .opacity(index < ended ? 0.4 : 1)
        .overlay(alignment: .topLeading) { nowLine(index) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(index))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private static let laneWidth: CGFloat = 8

    /// Green for free and orange for booked; a class leaves the lane empty.
    private func lane(_ index: Int) -> some View {
        let kind = laneKind(index)
        let opensRun = laneKind(index - 1) != kind
        let closesRun = laneKind(index + 1) != kind
        let radius: CGFloat = 4
        return UnevenRoundedRectangle(
            topLeadingRadius: opensRun ? radius : 0,
            bottomLeadingRadius: closesRun ? radius : 0,
            bottomTrailingRadius: closesRun ? radius : 0,
            topTrailingRadius: opensRun ? radius : 0
        )
        .fill(kind?.color ?? .clear)
        .padding(.top, opensRun ? 6 : 0)
        .padding(.bottom, closesRun ? 6 : 0)
        .frame(width: Self.laneWidth)
    }

    private enum LaneKind {
        case free, booked

        var color: Color {
            switch self {
            case .free: .green
            case .booked: .orange
            }
        }
    }

    private func laneKind(_ index: Int) -> LaneKind? {
        guard room.slots.indices.contains(index) else { return nil }
        switch room.slots[index] {
        case .free: return .free
        case .booked: return .booked
        case .course: return nil
        }
    }

    @ViewBuilder
    private func use(_ index: Int) -> some View {
        if room.slots.indices.contains(index) {
            switch room.slots[index] {
            case .free:
                EmptyView()
            case .booked:
                Text(String(localized: "empty_classroom_booked"))
                    .font(.subheadline)
                    .foregroundStyle(Color.orange)
            case .course(let name, let teacher):
                HStack(alignment: .firstTextBaseline, spacing: TigerDuckTheme.Spacing.sm) {
                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(policy.primaryTextColor)
                        .truncationMode(.tail)
                    if !teacher.isEmpty {
                        Text(teacher)
                            .font(.footnote)
                            .foregroundStyle(policy.secondaryTextColor)
                            .layoutPriority(1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func nowLine(_ index: Int) -> some View {
        if index == nowPeriod {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.tint)
                    .frame(height: 2)
                    .padding(.horizontal, TigerDuckTheme.Spacing.sm)
                Circle()
                    .fill(.tint)
                    .frame(width: 8, height: 8)
                    .padding(.leading, TigerDuckTheme.Spacing.xs)
            }
            .padding(.top, 5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var legend: some View {
        HStack(spacing: TigerDuckTheme.Spacing.lg) {
            legendItem(.green, String(localized: "empty_classroom_free"))
            legendItem(.orange, String(localized: "empty_classroom_booked"))
        }
        .font(.caption)
        .foregroundStyle(policy.secondaryTextColor)
        .frame(maxWidth: .infinity)
    }

    private func legendItem(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4)
                .fill(color)
                .frame(width: 8, height: 14)
            Text(title)
        }
    }

    private func accessibilityText(_ index: Int) -> String {
        let period = String(format: String(localized: "a11y_empty_classroom_period"), EmptyClassroomSchedule.periodIDs[index])
        let use: String
        switch room.slots.indices.contains(index) ? room.slots[index] : .free {
        case .free: use = String(localized: "empty_classroom_free")
        case .booked: use = String(localized: "empty_classroom_booked")
        case .course(let name, let teacher): use = teacher.isEmpty ? name : "\(name), \(teacher)"
        }
        return [period, EmptyClassroomViewModel.timeRange(of: index), use].joined(separator: ", ")
    }
}
