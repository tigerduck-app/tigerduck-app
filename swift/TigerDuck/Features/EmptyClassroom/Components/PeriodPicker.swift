import SwiftUI

/// The date menu, offering today and the 13 days after it, with the chosen period's times.
struct ClassroomTimeBar: View {
    let days: [Date]
    let selectedDay: Date
    let period: Int
    let policy: VisualStylePolicy
    let label: (Date) -> String
    let onSelect: (Date) -> Void

    var body: some View {
        HStack(spacing: TigerDuckTheme.Spacing.md) {
            dayMenu
            Spacer(minLength: 0)
            Text(EmptyClassroomViewModel.timeRange(of: period))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(policy.secondaryTextColor)
                .lineLimit(1)
        }
    }

    /// Glass on iOS 26 and a filled capsule below it, as the class table's header menu.
    @ViewBuilder
    private var dayMenu: some View {
        let menu = Menu {
            Picker(selection: Binding(get: { selectedDay }, set: onSelect)) {
                ForEach(days, id: \.self) { day in
                    Text(label(day)).tag(day)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: TigerDuckTheme.Spacing.xs) {
                Text(label(selectedDay))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(policy.primaryTextColor)
            .padding(.horizontal, TigerDuckTheme.Spacing.md)
            .padding(.vertical, TigerDuckTheme.Spacing.sm)
            .contentShape(Capsule())
        }
        if #available(iOS 26, *) {
            menu.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            menu.background(Capsule().fill(Color(uiColor: .secondarySystemFill)))
        }
    }
}

/// The 14 periods as chips, each its label over its start time. The current period's label is in
/// the tint, as a calendar marks today, and the periods already over are dimmed but can still be
/// chosen. The row opens on the current period, since the ones before it rarely matter.
struct PeriodChipRow: View {
    let selected: Int
    let current: Int?
    let ended: Int
    let policy: VisualStylePolicy
    let onSelect: (Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .headline) private var labelWidth: CGFloat = 30

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: TigerDuckTheme.Spacing.sm) {
                    ForEach(EmptyClassroomSchedule.periodIDs.indices, id: \.self) { index in
                        Button {
                            onSelect(index)
                        } label: {
                            chip(index)
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
            }
            .contentMargins(.horizontal, TigerDuckTheme.Spacing.lg, for: .scrollContent)
            .onAppear { proxy.scrollTo(current ?? selected, anchor: .leading) }
            .onChange(of: selected) { _, period in
                withAnimation(reduceMotion ? nil : .smoothSpring) {
                    proxy.scrollTo(period)
                }
            }
        }
    }

    private func chip(_ index: Int) -> some View {
        let isSelected = index == selected
        let id = EmptyClassroomSchedule.periodIDs[index]
        return VStack(spacing: 0) {
            Text(id)
                .font(.headline)
                .foregroundStyle(labelStyle(index, isSelected: isSelected))
            Text(EmptyClassroomSchedule.timeRange(of: index)?.start ?? "")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isSelected ? Color.white.opacity(0.9) : policy.secondaryTextColor)
        }
        .lineLimit(1)
        .frame(minWidth: labelWidth)
        .opacity(index < ended && !isSelected ? 0.4 : 1)
        .presetChip(policy: policy, isSelected: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: String(localized: "a11y_empty_classroom_period"), id))
        .accessibilityValue(accessibilityValue(index))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The times, and for the current period, that it is now.
    private func accessibilityValue(_ index: Int) -> String {
        let times = EmptyClassroomViewModel.timeRange(of: index)
        guard index == current else { return times }
        return "\(times), \(String(localized: "home_time_slider_now"))"
    }

    private func labelStyle(_ index: Int, isSelected: Bool) -> AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Color.white) }
        return index == current ? AnyShapeStyle(.tint) : AnyShapeStyle(policy.primaryTextColor)
    }
}
