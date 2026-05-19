import SwiftUI

/// Color picker for a single course. Surfaces the 20-color preset palette
/// alongside a SwiftUI `ColorPicker` so users can dial in any 24-bit RGB
/// hex — the active swatch (preset or custom) is ringed for confirmation,
/// and the model layer enforces uniqueness across the roster so picking a
/// color another class already uses displaces *that* class to a new one.
struct CourseColorPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let course: SDCourse
    let onSelect: (UInt32) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 5)

    @State private var customColor: Color
    /// Set by the preset-button path so the next `.onChange(of: customColor)`
    /// tick is skipped — preset taps already call `onSelect` directly, and
    /// the change observer would otherwise double-apply on macOS (where the
    /// sheet stays open) because `currentHex` can still be stale for that
    /// render pass.
    @State private var suppressNextColorChange = false

    init(course: SDCourse, onSelect: @escaping (UInt32) -> Void) {
        self.course = course
        self.onSelect = onSelect
        _customColor = State(initialValue: Color(hex: UInt(TigerDuckTheme.assignedHex(for: course.courseNo))))
    }

    /// Index of the preset that matches the course's currently-assigned hex,
    /// or `nil` when the user has dialed in a fully custom color via the
    /// `ColorPicker`. Drives the "ringed swatch" affordance.
    private var activePresetIndex: Int? {
        TigerDuckTheme.paletteIndex(for: course.courseNo)
    }

    private var currentHex: UInt32 {
        TigerDuckTheme.assignedHex(for: course.courseNo)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: TigerDuckTheme.Spacing.lg) {
                    header
                    presetGrid
                    customPickerRow
                }
                .padding(.top, TigerDuckTheme.Spacing.lg)
                .padding(.bottom, TigerDuckTheme.Spacing.xl)
            }
            .background(Color.backgroundPrimary)
            .navigationTitle(String(localized: "course_color_picker_title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_close")) { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: TigerDuckTheme.Spacing.md) {
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.sm)
                .fill(course.color)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(course.displayName)
                    .font(TigerDuckTheme.Typography.headline)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                Text(course.courseNo)
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    private var presetGrid: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(Array(TigerDuckTheme.courseColors.enumerated()), id: \.offset) { index, color in
                Button {
                    let hex = TigerDuckTheme.coursePaletteHexes[index]
                    suppressNextColorChange = true
                    customColor = Color(hex: UInt(hex))
                    onSelect(hex)
                    // Preset tap is a one-shot pick — close the sheet
                    // now. The custom ColorPicker path deliberately does
                    // *not* dismiss here because its `.onChange` fires on
                    // every drag tick.
                    dismiss()
                } label: {
                    swatch(color: color, isSelected: index == activePresetIndex)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    private var customPickerRow: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            Text(String(localized: "course_color_picker_custom_label"))
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)

            HStack(spacing: TigerDuckTheme.Spacing.md) {
                // Inline ColorPicker with no label — the section header above
                // labels it instead, leaving the row full-width for the swatch
                // + readout. `supportsOpacity: false` because the renderer
                // (and the on-disk hex map) is 24-bit only.
                ColorPicker(
                    String(localized: "course_color_picker_custom_label"),
                    selection: $customColor,
                    supportsOpacity: false
                )
                .labelsHidden()

                Text(String(format: "#%06X", currentHex))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(Color.textSecondary)

                Spacer()

                if activePresetIndex == nil {
                    Text(String(localized: "course_color_picker_custom_badge"))
                        .font(TigerDuckTheme.Typography.caption2)
                        .foregroundStyle(Color.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().stroke(Color.textSecondary.opacity(0.5), lineWidth: 0.5)
                        )
                }
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .onChange(of: customColor) { _, newValue in
                if suppressNextColorChange {
                    suppressNextColorChange = false
                    return
                }
                let hex = hexFrom(color: newValue)
                // Guard against the no-op tick SwiftUI emits when the picker
                // is first shown with the current course color — without this,
                // simply opening the sheet would issue a needless setColor
                // call and broadcast.
                guard hex != currentHex else { return }
                onSelect(hex)
            }
        }
    }

    @ViewBuilder
    private func swatch(color: Color, isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: 42, height: 42)
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(Color.textPrimary, lineWidth: 2.5)
                            .padding(-4)
                    }
                }
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1)
            }
        }
        .frame(height: 50)
        .contentShape(Circle())
    }

    /// Extract a 24-bit RGB hex from a SwiftUI `Color`. The picker hands us
    /// a `Color` that resolves through the active environment.
    ///
    /// On macOS, `NSColor(color)` may land in a color space whose
    /// `cgColor` representation isn't directly available — the API is
    /// declared non-optional but is documented to return nil in that
    /// case, and the picker's output catalog colors trip this in
    /// practice. Convert through `.sRGB` first so we always read RGBA
    /// from a well-defined space, and treat an unresolved CGColor as
    /// black (0) rather than crashing.
    private func hexFrom(color: Color) -> UInt32 {
        #if canImport(UIKit)
        let resolved: CGColor? = UIColor(color).cgColor
        #elseif canImport(AppKit)
        let resolved: CGColor? = NSColor(color).usingColorSpace(.sRGB)?.cgColor
        #else
        let resolved: CGColor? = nil
        #endif
        guard let cg = resolved else { return 0 }
        let components = cg.components ?? [0, 0, 0, 1]
        let r = UInt32(max(0, min(1, components[0])) * 255)
        let g = UInt32(max(0, min(1, components.count > 1 ? components[1] : components[0])) * 255)
        let b = UInt32(max(0, min(1, components.count > 2 ? components[2] : components[0])) * 255)
        return (r << 16) | (g << 8) | b
    }
}
