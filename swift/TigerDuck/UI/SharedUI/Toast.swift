import SwiftUI

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
    func toastHost() -> some View {
        modifier(ToastHost())
    }

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
            // VoiceOver's double tap on a dimmed control becomes a tap at its activation point,
            // which lands on the overlay as a finger's tap does.
            content
                .disabled(true)
                .overlay {
                    Button { showToast(reason) } label: { Color.clear.contentShape(.rect) }
                        .buttonStyle(.plain)
                        .accessibilityHidden(true)
                }
                .accessibilityHint(Text(reason))
        } else {
            content
        }
    }
}
