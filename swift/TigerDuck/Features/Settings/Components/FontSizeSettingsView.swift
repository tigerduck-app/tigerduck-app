import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Sub-page for picking the course-name font scale used in the class
/// table and home-screen widgets. The selection flows through
/// `AppState.courseCardFontScale` → `CourseCardFontScaleStore`
/// (App Group `UserDefaults`) and is applied at the specific course-name
/// `Text` views in `TimetableGridView` plus the widget course-name labels.
/// Widgets read the same value on their next render after `AppState`'s
/// `didSet` triggers `WidgetCenter.reloadAllTimelines()`.
///
/// Layout: a `Preview` section at the top renders a mock class-table
/// cluster so the user can see the effect on the actual UI surface, and
/// a `Slider` section below drives the scale. The mock includes one
/// "solo" cell and a two-course conflict cluster so the live preview
/// covers both rendering modes the user will see in the real timetable.
struct FontSizeSettingsView: View {
    @Environment(AppState.self) private var appState
    #if os(iOS)
    /// Matches the `TimeSliderViewModel` pattern — keep one generator
    /// alive for the lifetime of the view so `prepare()` actually warms
    /// the haptic engine; a fresh-per-call generator skips priming and
    /// the first selection feels delayed.
    @State private var hapticGenerator = UISelectionFeedbackGenerator()
    #endif
    /// Tracks the most recent snapped scale we've fired a haptic for, so
    /// the slider's high-frequency `onChange` callbacks only buzz when
    /// the value crosses a step boundary instead of on every drag tick.
    /// `nil` is the "no baseline yet" state — the first observation
    /// silently records the baseline so a layout-pass tick before
    /// `onAppear` can never fire a spurious haptic.
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
                        // Tap to nudge by one step, hold the slider to
                        // drag freely. The two "A" anchors mirror the
                        // iOS Settings → Display & Text Size pattern.
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
                // Slider with `step:` fires onChange on every snapped
                // tick. Gate the haptic on the normalized value so a
                // drag from 1.00× to 1.30× produces six discrete buzzes
                // (one per 0.05× boundary) and not one per render frame.
                // Mirrors the `TimeSliderViewModel` selectionChanged()
                // cadence the user already knows from Home.
                .onChange(of: appState.courseCardFontScale) { _, newValue in
                    let snapped = CourseCardFontScale.normalize(newValue)
                    defer { lastHapticScale = snapped }
                    // First observation establishes the baseline
                    // silently — only subsequent boundary crossings buzz.
                    guard let last = lastHapticScale, snapped != last else { return }
                    hapticGenerator.selectionChanged()
                    // Re-prime for the next tick so the kernel keeps the
                    // engine warm — `selectionChanged()` invalidates the
                    // primed state.
                    hapticGenerator.prepare()
                }
                .onAppear {
                    // Warm the engine up front so the first drag doesn't
                    // eat the priming latency.
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

    /// Format: `1.20×` (en) / `1,20×` (de/fr/...). Uses
    /// `.formatted(.number...)` so the decimal separator follows
    /// `Locale.current`. `.monospacedDigit()` is applied at the call
    /// site for stable column width during drags.
    private func scaleLabel(_ scale: Double) -> String {
        let normalized = CourseCardFontScale.normalize(scale)
        return normalized.formatted(.number.precision(.fractionLength(2))) + "×"
    }
}

/// Mock class-table preview that mirrors `TimetableGridView`'s solo-cell
/// and 2-course conflict-cluster geometry at a small scale, so the user
/// sees the slider's effect against the same visual surface they're
/// adjusting for. Strings are localizable mock course names — they
/// should read as realistic course titles in every locale, not stand
/// in as English-only placeholders.
private struct ClassCardPreview: View {
    let scale: Double

    private let cellHeight: CGFloat = 52
    private let rowSpacing: CGFloat = 3
    private let cornerRadius: CGFloat = 8
    @ScaledMetric(relativeTo: .caption2) private var courseNameBaseSize: CGFloat = 8

    private var courseFontSize: CGFloat {
        courseNameBaseSize * CGFloat(CourseCardFontScale.normalize(scale))
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
            .fill(Color.accentColor.opacity(0.35))
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

    /// Stacked two-cell stand-in for a conflict cluster. The real
    /// renderer interlocks two L shapes; mocking that here would drag in
    /// `ConflictLShape` for a preview. A simple two-row stack is enough
    /// to communicate "course names in adjacent cells stay readable
    /// after rescaling".
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
