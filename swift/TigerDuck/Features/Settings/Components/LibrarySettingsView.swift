import CoreHaptics
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// "Library and related features": the library feature switch and, on
/// iPhone, flip-to-library, in one group. `SettingsView`'s "Other settings"
/// section links here and to `OtherSettingsView`.
///
/// Turning the feature on goes through `LibraryWarningOverlay` first.
struct LibrarySettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showLibraryWarning = false
    @State private var pendingLibraryEnable = false
    @State private var warningFlash = false
    @State private var libraryWarningTask: Task<Void, Never>?
    @State private var hapticEngine: CHHapticEngine?
    @State private var hapticPlayer: CHHapticPatternPlayer?

    var body: some View {
        @Bindable var appState = appState
        List {
            Section {
                Toggle(String(localized: "settings_library_related_features"), isOn: libraryToggleBinding)
                if showsFlipToLibrary {
                    Toggle(
                        String(localized: "settings_flip_to_library_title"),
                        isOn: $appState.flipToLibraryEnabled
                    )
                }
            } footer: {
                if showsFlipToLibrary {
                    Text(String(localized: "settings_flip_to_library_summary"))
                }
            }
        }
        .navigationTitle(String(localized: "settings_library_related_features"))
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if showLibraryWarning {
                LibraryWarningOverlay(
                    isFlashing: $warningFlash,
                    onCancel: {
                        pendingLibraryEnable = false
                        showLibraryWarning = false
                        warningFlash = false
                    },
                    onConfirm: {
                        pendingLibraryEnable = false
                        appState.libraryFeatureEnabled = true
                        // Auto-add library tab if there's room
                        if !appState.configuredTabs.contains(.library),
                           appState.configuredTabs.count < 4 {
                            appState.configuredTabs.append(.library)
                        }
                        showLibraryWarning = false
                        warningFlash = false
                    }
                )
                .onAppear {
                    warningFlash = false
                    if !reduceMotion {
                        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                            warningFlash = true
                        }
                    }
                    triggerWarningVibration()
                }
                .onDisappear {
                    hapticPlayer = nil
                    hapticEngine?.stop()
                    hapticEngine = nil
                }
            }
        }
        .onDisappear {
            // Cancel any pending warning-overlay delay so it can't fire
            // (and the countdown loop in LibraryWarningOverlay can't try to
            // mutate state on a torn-down view) after this page closes.
            libraryWarningTask?.cancel()
            libraryWarningTask = nil
        }
    }

    /// Flip-to-Library: only available on iPhone (iPad use case is unclear
    /// and the issue scope says "phone only"), where the gesture routes to
    /// the Library tab. Android has the same switch on its library page,
    /// shown there only while the feature is on, which this matches.
    ///
    /// The row is a sub-setting of the library feature switch above it, so
    /// it goes away with the feature: with library off the gesture cannot
    /// fire (`FlipToLibraryModifier.shouldBeActive` and its fire-time guard
    /// both require `libraryFeatureEnabled`), and a live-looking switch for
    /// something that does nothing reads as broken.
    ///
    /// Reading `libraryFeatureEnabled` rather than `libraryToggleBinding`
    /// is deliberate: that binding also reports on for
    /// `pendingLibraryEnable`, so this row would appear behind the
    /// confirmation overlay and vanish again if the user cancels.
    /// Confirming brings it back on this same screen, still carrying
    /// whatever value was persisted, so the preference stays inspectable
    /// wherever it can actually do anything.
    private var showsFlipToLibrary: Bool {
        #if os(iOS)
        appState.libraryFeatureEnabled
            && UIDevice.current.userInterfaceIdiom == .phone
            && FlipDetector.isSupported
        #else
        false
        #endif
    }

    private var libraryToggleBinding: Binding<Bool> {
        Binding(
            get: { appState.libraryFeatureEnabled || pendingLibraryEnable },
            set: { newValue in
                if newValue {
                    guard !showLibraryWarning else { return }
                    pendingLibraryEnable = true
                    libraryWarningTask?.cancel()
                    libraryWarningTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        guard !Task.isCancelled else { return }
                        showLibraryWarning = true
                    }
                } else {
                    pendingLibraryEnable = false
                    appState.libraryFeatureEnabled = false
                    appState.configuredTabs.removeAll { AppFeature.libraryRelatedFeatures.contains($0) }
                }
            }
        )
    }

    private func triggerWarningVibration() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let engine = try CHHapticEngine()
            try engine.start()
            self.hapticEngine = engine
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
                ],
                relativeTime: 0,
                duration: 1.0
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            self.hapticPlayer = player
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Silently fail on devices without haptic support
        }
    }
}

// MARK: - Library Warning Overlay

private struct LibraryWarningOverlay: View {
    @Binding var isFlashing: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var countdown = 5
    @State private var confirmEnabled = false

    private var confirmLabel: String {
        if confirmEnabled {
            return String(localized: "settings_library_warning_confirm")
        }
        let format = String(localized: "settings_library_warning_confirm_countdown")
        return String(format: format, countdown)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                // Flashing warning title
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(String(localized: "settings_library_warning_title"))
                }
                .font(.headline.bold())
                .foregroundStyle(.red)
                .opacity(isFlashing ? 0.15 : 1.0)

                JustifiedText(
                    String(localized: "settings_library_warning_message"),
                    textStyle: .subheadline
                )

                buttons
            }
            .padding(24)
            .modifier(GlassDialogSurface())
            .padding(.horizontal, 32)
        }
        .transition(.opacity)
        .task {
            for i in stride(from: 4, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                countdown = i
            }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                confirmEnabled = true
            }
        }
    }

    /// Liquid Glass buttons on iOS 26; the hand-rolled red / grey pills
    /// stay for iOS 18–25 where `.glass` does not exist.
    @ViewBuilder
    private var buttons: some View {
        if #available(iOS 26, *) {
            VStack(spacing: 10) {
                Button(action: onConfirm) {
                    Text(confirmLabel)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(!confirmEnabled)

                Button(action: onCancel) {
                    Text(String(localized: "settings_library_warning_dismiss"))
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        } else {
            VStack(spacing: 10) {
                Button(action: onConfirm) {
                    Text(confirmLabel)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            confirmEnabled ? Color.red : Color.red.opacity(0.35),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!confirmEnabled)

                Button(action: onCancel) {
                    Text(String(localized: "settings_library_warning_dismiss"))
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Dialog surface: Liquid Glass on iOS 26, regular material before it.
private struct GlassDialogSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 28))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }
}
