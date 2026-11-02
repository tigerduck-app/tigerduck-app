import SwiftUI

struct ColorPickerSheet: View {
    struct Labels {
        let title: String
        let custom: String
        let customBadge: String
        /// A format of the swatch's place in the palette, from 1.
        let swatch: String
    }

    @Environment(\.dismiss) private var dismiss

    let name: String
    let detail: String?
    let labels: Labels
    private let appliedHex: () -> UInt32

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 5)

    @State private var customColor: Color
    @State private var suppressNextColorChange = false
    @State private var customPicks: CustomColorPickDebouncer

    /// `appliedHex` reads the color as it is now saved.
    init(
        name: String, detail: String?, labels: Labels, appliedHex: @escaping () -> UInt32, signIn: SignIn,
        onSelect: @escaping (UInt32) -> Void
    ) {
        self.name = name
        self.detail = detail
        self.labels = labels
        self.appliedHex = appliedHex
        _customColor = State(initialValue: Color(hex: UInt(appliedHex())))
        _customPicks = State(initialValue: CustomColorPickDebouncer(
            apply: onSelect,
            appliedHex: appliedHex,
            isCurrent: { signIn.isCurrent }
        ))
    }

    private var activePresetIndex: Int? {
        TigerDuckTheme.coursePaletteHexes.firstIndex(of: currentHex)
    }

    private var currentHex: UInt32 {
        appliedHex()
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
            .navigationTitle(labels.title)
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
                .fill(Color(hex: UInt(currentHex)))
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(TigerDuckTheme.Typography.headline)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(TigerDuckTheme.Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                }
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
                .accessibilityLabel(Text(String(format: labels.swatch, index + 1)))
                .accessibilityAddTraits(index == activePresetIndex ? .isSelected : [])
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    private var customPickerRow: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            Text(labels.custom)
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)

            HStack(spacing: TigerDuckTheme.Spacing.md) {
                ColorPicker(
                    labels.custom,
                    selection: $customColor,
                    supportsOpacity: false
                )
                .labelsHidden()

                Text(String(format: "#%06X", currentHex))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(Color.textSecondary)

                Spacer()

                if activePresetIndex == nil {
                    Text(labels.customBadge)
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
                // This also sees the no-op tick SwiftUI emits when the picker first shows
                // the current course color; the debouncer applies nothing for it, so just
                // opening the sheet issues no setColor call and broadcast.
                customPicks.pick(newValue.rgbHex)
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
}

extension ColorPickerSheet {
    init(course: CourseStore.Course, signIn: SignIn, onSelect: @escaping (UInt32) -> Void) {
        let courseNo = course.courseNo
        self.init(
            name: course.displayName,
            detail: courseNo,
            labels: Labels(
                title: String(localized: "course_color_picker_title"),
                custom: String(localized: "course_color_picker_custom_label"),
                customBadge: String(localized: "course_color_picker_custom_badge"),
                swatch: String(localized: "a11y_course_color_swatch")
            ),
            appliedHex: { TigerDuckTheme.assignedHex(for: courseNo) },
            signIn: signIn,
            onSelect: onSelect
        )
    }
}

/// Holds a custom colour back until the drag pauses. The `ColorPicker` reports every
/// step of a drag.
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
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await AppClock.sleep(until: ContinuousClock.now + $0) }
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
