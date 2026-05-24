#if os(iOS)
import SwiftUI
import UIKit

// MARK: - Identifier

/// Strongly-typed identifier for every one-shot "first time you did X, want
/// us to keep doing it?" prompt in the app. Adding a new prompt = add a case.
///
/// The `rawValue` is appended to a fixed `firstTriggerPromptSeen.` prefix and
/// stored in `UserDefaults`, so renaming a case is a one-way migration: the
/// new key reverts to "unseen" for upgrading users. Pick names that read well
/// in user-facing analytics ("flipToLibrary"), not implementation details.
enum FirstTriggerPromptKey: String {
    case flipToLibrary
}

// MARK: - Content model

/// A single "first trigger" prompt's content. Constructed lazily by the
/// caller via `FirstTriggerPromptCenter.requestIfFirstTime(_:build:)` so the
/// closures (and the strings they pull from localization) are not evaluated
/// when the prompt has already been seen.
struct FirstTriggerPromptContent {
    let title: String
    let message: String
    let animation: FirstTriggerAnimation
    let acceptLabel: String
    let declineLabel: String
    let onAccept: () -> Void
    let onDecline: () -> Void
}

/// Animation variants available for the prompt's hero illustration. Add cases
/// as new features adopt the prompt — each case gets a small SwiftUI sub-view
/// inside `FirstTriggerAnimationView`.
enum FirstTriggerAnimation {
    case phoneFlip
}

// MARK: - Center (state holder)

/// Process-wide queue of pending first-trigger prompts. The root view binds a
/// `.sheet(item:)` to `pending` via `.firstTriggerPromptHost()`. At most one
/// prompt is visible at a time; rapid `requestIfFirstTime(...)` calls past
/// the first are dropped silently.
///
/// Persistence is plain `UserDefaults` (not the `Defaults` library) because
/// keys are constructed dynamically from the enum's `rawValue` and the set of
/// known keys grows organically as features are added.
@Observable
final class FirstTriggerPromptCenter {
    static let shared = FirstTriggerPromptCenter()

    /// Wraps the content with an Identifiable shell so SwiftUI's
    /// `.sheet(item:)` can drive present/dismiss directly off this property.
    struct Pending: Identifiable {
        let id = UUID()
        let key: FirstTriggerPromptKey
        let content: FirstTriggerPromptContent
    }

    var pending: Pending?

    private init() {}

    func hasSeen(_ key: FirstTriggerPromptKey) -> Bool {
        UserDefaults.standard.bool(forKey: Self.storageKey(key))
    }

    /// Show the prompt iff it hasn't been seen and nothing else is currently
    /// pending. `build` is invoked only when the prompt will actually be
    /// shown — cheap to call from a hot path (e.g. a sensor callback).
    func requestIfFirstTime(
        _ key: FirstTriggerPromptKey,
        build: () -> FirstTriggerPromptContent
    ) {
        guard pending == nil, !hasSeen(key) else { return }
        pending = Pending(key: key, content: build())
    }

    /// Called by the sheet's buttons. Marks the prompt seen and clears
    /// `pending` (dismissing the sheet) BEFORE invoking the user's closure
    /// so that any synchronous SwiftUI work the closure triggers — e.g.
    /// mutating `AppState` which fans out to `onChange` observers — runs
    /// against an already-cleared presentation state.
    ///
    /// The seen flag is written here, not on `.onAppear`, so that a sheet
    /// dismissed by anything other than a Keep/Turn-off tap (app backgrounded,
    /// root view recreated, another presentation steals focus) does NOT count
    /// as the user having made a choice. Re-showing on a later flip is the
    /// correct behavior — silently treating "seen" as "agreed to keep it on"
    /// would arm the gesture without consent.
    func finish(accept: Bool) {
        guard let p = pending else { return }
        markSeen(p.key)
        pending = nil
        if accept {
            p.content.onAccept()
        } else {
            p.content.onDecline()
        }
    }

    func markSeen(_ key: FirstTriggerPromptKey) {
        UserDefaults.standard.set(true, forKey: Self.storageKey(key))
    }

    private static func storageKey(_ key: FirstTriggerPromptKey) -> String {
        "firstTriggerPromptSeen.\(key.rawValue)"
    }
}

// MARK: - Sheet

private struct FirstTriggerPromptSheet: View {
    let promptKey: FirstTriggerPromptKey
    let content: FirstTriggerPromptContent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            FirstTriggerAnimationView(animation: content.animation)
                .frame(height: 140)

            Text(content.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text(content.message)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Button {
                    FirstTriggerPromptCenter.shared.finish(accept: true)
                } label: {
                    Text(content.acceptLabel)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    FirstTriggerPromptCenter.shared.finish(accept: false)
                } label: {
                    Text(content.declineLabel)
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 40)
        .onAppear {
            // Heavy impact on sheet appearance so the prompt is felt as well
            // as seen — every first-trigger prompt is an unexpected interrupt
            // and the haptic anchors it to the gesture that caused it.
            //
            // The "seen" flag is recorded in `finish(accept:)` on a Keep or
            // Turn-off tap, not here — see that method's comment.
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred(intensity: 1.0)
        }
    }
}

// MARK: - Animation

private struct FirstTriggerAnimationView: View {
    let animation: FirstTriggerAnimation
    @State private var flipped = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// SF Symbol switches between iPhone and iPad glyph based on idiom so the
    /// same reusable prompt looks right on either device when future features
    /// adopt this animation. Flip-to-Library itself is iPhone-only, but the
    /// prompt system is feature-agnostic.
    private var deviceSymbol: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad.gen2" : "iphone.gen3"
    }

    var body: some View {
        switch animation {
        case .phoneFlip:
            Image(systemName: deviceSymbol)
                .font(.system(size: 96, weight: .regular))
                .foregroundStyle(.tint)
                // Rotate around the device's long edge (Y axis in portrait):
                // the phone "tips over sideways" the way you'd naturally flip
                // it to lay it face-down on a table.
                .rotation3DEffect(
                    .degrees(flipped ? 180 : 0),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.4
                )
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(
                        .easeInOut(duration: 1.6).repeatForever(autoreverses: true)
                    ) {
                        flipped = true
                    }
                }
                .accessibilityLabel(Text(String(localized: "first_trigger_phone_flip_accessibility")))
        }
    }
}

// MARK: - Host modifier

private struct FirstTriggerPromptHost: ViewModifier {
    @State private var center = FirstTriggerPromptCenter.shared

    func body(content: Content) -> some View {
        @Bindable var center = center
        return content.sheet(item: $center.pending) { pending in
            FirstTriggerPromptSheet(promptKey: pending.key, content: pending.content)
                // `.medium` clips the animation + 2-button stack on standard
                // phones. Tall fraction gives the prompt room to breathe
                // without forcing a full-screen sheet (which would feel
                // disproportionate for an opt-in question).
                //
                // No drag indicator: the user MUST tap Keep or Turn off
                // (interactiveDismissDisabled) so a visible grab handle
                // would advertise a gesture that does nothing.
                .presentationDetents([.fraction(0.7)])
                .interactiveDismissDisabled()
        }
    }
}

extension View {
    /// Install the first-trigger prompt sheet host. Apply once near the root.
    func firstTriggerPromptHost() -> some View {
        modifier(FirstTriggerPromptHost())
    }
}
#endif
