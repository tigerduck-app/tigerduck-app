import SwiftUI

struct CourseColorPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let course: SDCourse

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 5)

    @State private var customColor: Color
    @State private var suppressNextColorChange = false
    @State private var customPicks: CustomColorPickDebouncer

    init(course: SDCourse, isCurrent: @escaping () -> Bool, onSelect: @escaping (UInt32) -> Void) {
        self.course = course
        _customColor = State(initialValue: Color(hex: UInt(TigerDuckTheme.assignedHex(for: course.courseNo))))
        let courseNo = course.courseNo
        _customPicks = State(initialValue: CustomColorPickDebouncer(
            apply: onSelect,
            appliedHex: { TigerDuckTheme.assignedHex(for: courseNo) },
            isCurrent: isCurrent
        ))
    }

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
        .onDisappear { customPicks.flush() }
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
                    customPicks.select(hex)
                    dismiss()
                } label: {
                    swatch(color: color, isSelected: index == activePresetIndex)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(String(format: String(localized: "a11y_course_color_swatch"), index + 1)))
                .accessibilityAddTraits(index == activePresetIndex ? .isSelected : [])
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
                customPicks.pick(hexFrom(color: newValue))
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

@MainActor
final class CustomColorPickDebouncer {
    static let pause: Duration = .milliseconds(300)

    private let apply: (UInt32) -> Void
    private let appliedHex: () -> UInt32
    private let isCurrent: () -> Bool
    private let sleep: @Sendable (Duration) async -> Void
    private var pendingHex: UInt32?
    private(set) var pendingTask: Task<Void, Never>?

    init(
        apply: @escaping (UInt32) -> Void,
        appliedHex: @escaping () -> UInt32,
        isCurrent: @escaping () -> Bool,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.apply = apply
        self.appliedHex = appliedHex
        self.isCurrent = isCurrent
        self.sleep = sleep
    }

    func pick(_ hex: UInt32) {
        guard hex != appliedHex() else {
            cancel()
            return
        }
        pendingHex = hex
        pendingTask?.cancel()
        let sleep = sleep
        pendingTask = Task { [weak self] in
            await sleep(Self.pause)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        pendingTask?.cancel()
        pendingTask = nil
        guard let hex = pendingHex else { return }
        pendingHex = nil
        guard isCurrent() else { return }
        apply(hex)
    }

    func select(_ hex: UInt32) {
        cancel()
        guard isCurrent() else { return }
        apply(hex)
    }

    func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
        pendingHex = nil
    }
}
