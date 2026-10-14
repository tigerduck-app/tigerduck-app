import SwiftUI

/// One building's free rooms by floor, under a row of building chips with their free-room
/// counts. A building with no free room offers the nearest ones that have one, and the next
/// period.
struct BuildingSection: View {
    let directory: BuildingDirectory
    let shown: String
    let period: Int
    let ended: Int
    let policy: VisualStylePolicy
    let name: (String) -> String
    let onPick: (String) -> Void
    /// Nil at the last period of the day.
    let onNextPeriod: (() -> Void)?
    let onRoom: (RoomUsage) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var glyphSize: CGFloat = 34
    @ScaledMetric(relativeTo: .body) private var nextButtonSize: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name(shown))
                .font(TigerDuckTheme.Typography.title)
                .foregroundStyle(policy.primaryTextColor)
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            chips
                .padding(.top, TigerDuckTheme.Spacing.md)
            let floors = directory.floors(of: shown)
            if floors.isEmpty {
                noFreeRoom
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                    .padding(.top, TigerDuckTheme.Spacing.lg)
            } else {
                ForEach(floors) { floor in
                    floorCard(floor)
                        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                        .padding(.top, TigerDuckTheme.Spacing.lg)
                }
            }
        }
    }

    /// Scrolled to the building shown, which can sort past the screen's edge.
    private var chips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: TigerDuckTheme.Spacing.sm) {
                    ForEach(directory.buildings) { building in
                        chip(building, isSelected: building.code == shown)
                            .id(building.code)
                    }
                }
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            }
            .onAppear { proxy.scrollTo(shown, anchor: .center) }
            .onChange(of: shown) { _, code in
                withAnimation(reduceMotion ? nil : .smoothSpring) {
                    proxy.scrollTo(code, anchor: .center)
                }
            }
        }
    }

    private func chip(_ building: BuildingDirectory.Building, isSelected: Bool) -> some View {
        Button {
            onPick(building.code)
        } label: {
            HStack(spacing: TigerDuckTheme.Spacing.sm) {
                Text(building.code)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(isSelected ? Color.white : policy.primaryTextColor)
                count(building.free.count, isSelected: isSelected)
            }
            .presetChip(policy: policy, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name(building.code))
        .accessibilityValue(String(format: String(localized: "a11y_empty_classroom_free_count"), building.free.count))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func count(_ count: Int, isSelected: Bool) -> some View {
        let fill: Color = isSelected ? .white.opacity(0.24) : count > 0 ? .green.opacity(0.2) : Color.textPrimary.opacity(0.08)
        let text: Color = isSelected ? .white : count > 0 ? .green : policy.secondaryTextColor
        return Text(count, format: .number)
            .font(.footnote.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(text)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(minWidth: 24)
            .background(Capsule().fill(fill))
    }

    private func floorCard(_ floor: BuildingDirectory.Floor) -> some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
            Text(floor.label)
                .font(.footnote.weight(.bold))
                .foregroundStyle(policy.secondaryTextColor)
                .padding(.horizontal, TigerDuckTheme.Spacing.xs)
            VStack(spacing: 0) {
                ForEach(Array(floor.rooms.enumerated()), id: \.element.id) { index, room in
                    if index > 0 {
                        Divider().padding(.leading, TigerDuckTheme.Spacing.lg)
                    }
                    RoomRow(room: room, period: period, ended: ended, policy: policy, onRoom: onRoom)
                }
            }
            .presetCard(policy: policy)
        }
    }

    private var noFreeRoom: some View {
        VStack(spacing: TigerDuckTheme.Spacing.md) {
            Image(systemName: "building.2")
                .font(.system(size: glyphSize))
                .foregroundStyle(policy.secondaryTextColor)
            Text(String(localized: "empty_classroom_no_free_rooms"))
                .font(.headline)
                .foregroundStyle(policy.primaryTextColor)
                .multilineTextAlignment(.center)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: TigerDuckTheme.Spacing.sm) { ways }
                VStack(spacing: TigerDuckTheme.Spacing.sm) { ways }
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.vertical, TigerDuckTheme.Spacing.xl)
        .frame(maxWidth: .infinity)
        .presetCard(policy: policy)
    }

    /// The nearest buildings with a free room, and the next period.
    @ViewBuilder
    private var ways: some View {
        ForEach(directory.nearby(shown)) { building in
            chip(building, isSelected: false)
        }
        if let onNextPeriod {
            Button(action: onNextPeriod) {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: nextButtonSize, height: nextButtonSize)
                    .background(Circle().fill(.tint))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "a11y_empty_classroom_next_period"))
        }
    }
}
