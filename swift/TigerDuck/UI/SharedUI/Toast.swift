import SwiftUI

/// Shows a short message in the nearest `toastHost()`; without one it does nothing.
struct ShowToastAction {
    fileprivate let show: (LocalizedStringResource) -> Void

    func callAsFunction(_ message: LocalizedStringResource) {
        show(message)
    }
}

extension EnvironmentValues {
    @Entry var showToast = ShowToastAction { _ in }
}

extension View {
    /// Lets the views inside show a toast at the bottom, which lets touches through, goes away
    /// on its own and is read out by VoiceOver.
    func toastHost() -> some View {
        modifier(ToastHost())
    }

    /// Looks disabled and, when tapped, shows `reason` in a toast instead of acting. A nil
    /// reason leaves the view as it is.
    func disabled(because reason: LocalizedStringResource?) -> some View {
        modifier(DisabledWithReason(closedReason: reason))
    }
}

private struct ToastHost: ViewModifier {
    static let duration: Duration = .seconds(2.5)

    private struct Shown {
        let id = UUID()
        let toastText: LocalizedStringResource
    }

    @State private var shown: Shown?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .environment(\.showToast, ShowToastAction { message in
                shown = Shown(toastText: message)
                AccessibilityNotification.Announcement(String(localized: message)).post()
            })
            .overlay(alignment: .bottom) {
                if let shown {
                    ToastView(toastText: shown.toastText)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .task(id: shown.id) {
                            do { try await AppClock.sleep(until: .now + Self.duration) } catch { return }
                            self.shown = nil
                        }
                }
            }
            .animation(reduceMotion ? nil : .smoothSpring, value: shown?.id)
    }
}

private struct ToastView: View {
    let toastText: LocalizedStringResource

    var body: some View {
        Text(toastText)
            .font(TigerDuckTheme.Typography.body)
            .foregroundStyle(Color.textPrimary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .padding(.vertical, TigerDuckTheme.Spacing.md)
            .glassCard(cornerRadius: TigerDuckTheme.CornerRadius.xl)
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .padding(.bottom, TigerDuckTheme.Spacing.xl)
            .allowsHitTesting(false)
    }
}

private struct DisabledWithReason: ViewModifier {
    let closedReason: LocalizedStringResource?
    @Environment(\.showToast) private var showToast

    func body(content: Content) -> some View {
        if let reason = closedReason {
            // A disabled element ignores VoiceOver's activation, so only the content inside is disabled.
            content
                .disabled(true)
                .accessibilityElement(children: .combine)
                .accessibilityHint(Text(reason))
                .accessibilityAction { showToast(reason) }
                .overlay {
                    Button { showToast(reason) } label: { Color.clear.contentShape(.rect) }
                        .buttonStyle(.plain)
                        .accessibilityHidden(true)
                }
        } else {
            content
        }
    }
}
