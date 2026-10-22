import SwiftUI
#if os(iOS)
import UIKit
#endif

struct FontSizeSettingsView: View {
    @Environment(AppState.self) private var appState
    #if os(iOS)
    /// Matches the `TimeSliderViewModel` pattern — keep one generator
    /// alive for the lifetime of the view so `prepare()` actually warms
    /// the haptic engine; a fresh-per-call generator skips priming and
    /// the first selection feels delayed.
    @State private var hapticGenerator = UISelectionFeedbackGenerator()
    #endif
    @State private var lastHapticScale: Double?

    var body: some View {
        @Bindable var appState = appState
        List {
            Section {
                ClassCardPreview(scale: appState.courseCardFontScale)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } header: {
                Text(String(localized: "settings_font_size_preview_section"))
            } footer: {
                Text(String(localized: "settings_font_size_preview_footer"))
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("A")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Slider(
                            value: $appState.courseCardFontScale,
                            in: CourseCardFontScale.minimum...CourseCardFontScale.maximum,
                            step: CourseCardFontScale.step
                        )
                        Text("A")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        Text(scaleLabel(appState.courseCardFontScale))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                .padding(.vertical, 4)
                #if os(iOS)
                .onChange(of: appState.courseCardFontScale) { _, newValue in
                    let snapped = CourseCardFontScale.normalize(newValue)
                    defer { lastHapticScale = snapped }
                    guard let last = lastHapticScale, snapped != last else { return }
                    hapticGenerator.selectionChanged()
                    // Re-prime for the next tick so the kernel keeps the
                    // engine warm — `selectionChanged()` invalidates the
                    // primed state.
                    hapticGenerator.prepare()
                }
                .onAppear {
                    hapticGenerator.prepare()
                    if lastHapticScale == nil {
                        lastHapticScale = CourseCardFontScale.normalize(appState.courseCardFontScale)
                    }
                }
                #endif

                Button {
                    appState.courseCardFontScale = CourseCardFontScale.default
                } label: {
                    Text(String(localized: "settings_font_size_reset_button"))
                        .foregroundStyle(.primary)
                }
                .disabled(
                    CourseCardFontScale.normalize(appState.courseCardFontScale)
                        == CourseCardFontScale.default
                )
            } header: {
                Text(String(localized: "settings_font_size_picker_section"))
            }
        }
        .navigationTitle(String(localized: "settings_font_size_title"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func scaleLabel(_ scale: Double) -> String {
        let normalized = CourseCardFontScale.normalize(scale)
        return normalized.formatted(.number.precision(.fractionLength(2))) + "×"
    }
}

private struct ClassCardPreview: View {
    let scale: Double

    private let cellHeight: CGFloat = 52
    private let rowSpacing: CGFloat = 3
    private let cornerRadius: CGFloat = 8
    @ScaledMetric(relativeTo: .caption2) private var courseNameBaseSize: CGFloat = 8

    private var courseFontSize: CGFloat {
        courseNameBaseSize * CGFloat(CourseCardFontScale.renderScale(scale))
    }

    var body: some View {
        HStack(alignment: .top, spacing: rowSpacing) {
            soloCell
                .frame(maxWidth: .infinity)
                .frame(height: cellHeight)

            conflictCluster
                .frame(maxWidth: .infinity)
                .frame(height: cellHeight * 2 + rowSpacing)
        }
        .padding(.horizontal, 4)
    }

    private var soloCell: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(.tint.opacity(0.35))
            .overlay {
                Text(String(localized: "settings_font_size_preview_course_name"))
                    .font(.system(size: courseFontSize, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
                    .padding(2)
            }
    }

    private var conflictCluster: some View {
        VStack(spacing: rowSpacing) {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.green.opacity(0.4))
                .overlay {
                    Text(String(localized: "settings_font_size_preview_course_name_alt_1"))
                        .font(.system(size: courseFontSize, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.center)
                        .padding(2)
                }
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.orange.opacity(0.4))
                .overlay {
                    Text(String(localized: "settings_font_size_preview_course_name_alt_2"))
                        .font(.system(size: courseFontSize, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.center)
                        .padding(2)
                }
        }
    }
}
