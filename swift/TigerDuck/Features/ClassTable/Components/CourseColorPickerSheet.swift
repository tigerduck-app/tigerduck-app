import SwiftUI

/// Palette picker for overriding a single course's color. Displays the full
/// ``TigerDuckTheme/courseColors`` palette; the currently-active swatch is
/// ringed and a "恢復預設" row clears any user override so the course falls
/// back to its deterministic default.
struct CourseColorPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let course: SDCourse
    let onSelect: (Int) -> Void
    let onReset: () -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 5)

    private var activeIndex: Int {
        TigerDuckTheme.paletteIndex(for: course.courseNo)
    }

    private var hasOverride: Bool {
        TigerDuckTheme.hasCustomColor(for: course.courseNo)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: TigerDuckTheme.Spacing.lg) {
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

                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(Array(TigerDuckTheme.courseColors.enumerated()), id: \.offset) { index, color in
                        Button {
                            onSelect(index)
                        } label: {
                            swatch(color: color, isSelected: index == activeIndex)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)

                Spacer()

                if hasOverride {
                    Button(role: .destructive) {
                        onReset()
                    } label: {
                        Label(String(localized: "course_color_picker_reset_action"), systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                    .padding(.bottom, TigerDuckTheme.Spacing.md)
                }
            }
            .padding(.top, TigerDuckTheme.Spacing.lg)
            .background(Color.backgroundPrimary)
            .navigationTitle(String(localized: "course_color_picker_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_close")) { dismiss() }
                }
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
