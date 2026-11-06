import SwiftUI
import TigerDuckCore

struct AccentGradientEditor: View {
    let preferences: AppPreferences

    @Environment(\.dismiss) private var dismiss
    @State private var draft: AccentGradient

    init(preferences: AppPreferences) {
        self.preferences = preferences
        _draft = State(initialValue: preferences.accent)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { preview }
                if draft.isGradient {
                    Section {
                        stylePicker
                        if draft.style == .linear { directionPicker }
                    }
                }
                Section {
                    ForEach(Array(draft.stops.enumerated()), id: \.offset) { index, _ in
                        AccentGradientStopRow(draft: $draft, index: index)
                    }
                    .onMove { draft.stops.move(fromOffsets: $0, toOffset: $1) }
                    if draft.canAddStop { addButton }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "settings_accent_gradient_custom"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .environment(\.editMode, .constant(.active))
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Label(String(localized: "action_cancel"), systemImage: "xmark")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        preferences.accent = readable
                        dismiss()
                    } label: {
                        Label(String(localized: "color_picker_apply"), systemImage: "checkmark")
                    }
                }
            }
        }
    }

    private var readable: AccentGradient {
        var readable = draft
        readable.stops = draft.stops.map(AccentContrast.readable)
        return readable
    }

    private func fill(_ accent: AccentGradient) -> AnyShapeStyle {
        accent.shapeStyle(color: AppPreferences.accentColor(hex:))
    }

    private var preview: some View {
        VStack(spacing: TigerDuckTheme.Spacing.md) {
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg).fill(fill(readable)).frame(height: 96)
            HStack {
                Image(systemName: "chart.bar.fill")
                    .font(.title)
                    .foregroundStyle(.tint)
                Spacer()
                Image(systemName: "square.and.pencil")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.tint))
                Spacer()
                Image(systemName: "house.fill")
                    .font(.title3)
                    .foregroundStyle(AppPreferences.accentColor(hex: readable.first))
                    .frame(width: 64, height: 44)
                    .background(Capsule().fill(.quaternary))
                Spacer()
                Toggle(isOn: .constant(true)) { EmptyView() }
                    .labelsHidden()
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.sm)
        }
        .tint(readable.tintStyle(color: AppPreferences.accentColor(hex:)))
        .accessibilityHidden(true)
        .padding(.vertical, TigerDuckTheme.Spacing.xs)
    }

    private var stylePicker: some View {
        HStack(spacing: 0) {
            ForEach(AccentGradient.Style.allCases, id: \.self) { style in
                choice(selected: draft.style == style, name: style.titleKey, radius: TigerDuckTheme.CornerRadius.lg) { draft.style = style } swatch: {
                    RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg)
                        .fill(sample { $0.style = style })
                        .frame(width: 64, height: 64)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, TigerDuckTheme.Spacing.xs)
    }

    private var directionPicker: some View {
        HStack(spacing: 0) {
            ForEach(Array(AccentGradient.Direction.allCases.enumerated()), id: \.element) { index, direction in
                choice(selected: draft.direction == direction, name: direction.titleKey, radius: TigerDuckTheme.CornerRadius.sm) {
                    draft.direction = direction
                } swatch: {
                    RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.sm)
                        .fill(sample { $0.direction = direction })
                        .frame(width: 32, height: 32)
                        .overlay {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .rotationEffect(.degrees(Double(index) * 45))
                        }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, TigerDuckTheme.Spacing.xs)
    }

    private func sample(_ change: (inout AccentGradient) -> Void) -> AnyShapeStyle {
        var sample = readable
        change(&sample)
        return fill(sample)
    }

    private func choice(
        selected: Bool, name: LocalizedStringResource, radius: CGFloat, action: @escaping () -> Void,
        @ViewBuilder swatch: () -> some View
    ) -> some View {
        Button(action: action) {
            swatch()
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: radius + TigerDuckTheme.Spacing.xs)
                            .strokeBorder(Color.textPrimary, lineWidth: 2.5)
                            .padding(-TigerDuckTheme.Spacing.xs)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(name))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var addButton: some View {
        Button {
            let presets = AppPreferences.themeColors.map(\.hex)
            draft.stops.append(presets.first { !draft.stops.contains($0) } ?? draft.stops[draft.stops.count - 1])
        } label: {
            Label {
                Text(String(localized: "action_add")).foregroundStyle(Color.textPrimary)
            } icon: {
                Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(.white, .green)
            }
        }
    }
}

extension AccentGradient.Style {
    var titleKey: LocalizedStringResource {
        switch self {
        case .linear: "settings_accent_gradient_style_linear"
        case .radial: "settings_accent_gradient_style_radial"
        case .angular: "settings_accent_gradient_style_angular"
        case .mesh: "settings_accent_gradient_style_mesh"
        }
    }
}

extension AccentGradient.Direction {
    var titleKey: LocalizedStringResource {
        switch self {
        case .leftToRight: "settings_accent_gradient_direction_left_to_right"
        case .topLeftToBottomRight: "settings_accent_gradient_direction_top_left_to_bottom_right"
        case .topToBottom: "settings_accent_gradient_direction_top_to_bottom"
        case .topRightToBottomLeft: "settings_accent_gradient_direction_top_right_to_bottom_left"
        case .rightToLeft: "settings_accent_gradient_direction_right_to_left"
        case .bottomRightToTopLeft: "settings_accent_gradient_direction_bottom_right_to_top_left"
        case .bottomToTop: "settings_accent_gradient_direction_bottom_to_top"
        case .bottomLeftToTopRight: "settings_accent_gradient_direction_bottom_left_to_top_right"
        }
    }
}
