import SwiftUI
import UserNotifications

/// The onboarding page that asks for notification permission.
struct OnboardingNotificationsPage: View {
    let status: UNAuthorizationStatus
    let isRequesting: Bool
    let onRequest: () -> Void
    let onNext: () -> Void

    var body: some View {
        OnboardingPageView(
            icon: "bell.badge.fill",
            title: String(localized: "onboarding_permissions_title"),
            subtitle: String(localized: "onboarding_permissions_subtitle"),
            accentColor: .orange,
            content: {
                VStack(spacing: TigerDuckTheme.Spacing.md) {
                    statusRow

                    #if canImport(UIKit)
                    if status == .denied {
                        Button(String(localized: "action_go_to_settings")) {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                    #endif
                }
            },
            actions: {
                VStack(spacing: TigerDuckTheme.Spacing.md) {
                    Button(String(localized: "onboarding_skip_for_now"), action: onNext)
                        .foregroundStyle(Color.textSecondary)

                    if status != .notDetermined {
                        Button(String(localized: "action_next"), action: onNext)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                }
            }
        )
    }

    @ViewBuilder
    private var statusRow: some View {
        switch status {
        case .authorized, .provisional, .ephemeral:
            Label(String(localized: "bulletin_push_status_registration_done"), systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.green)
        case .denied:
            Label(String(localized: "bulletin_push_status_denied"), systemImage: "xmark.octagon.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.red)
        case .notDetermined:
            Button(action: onRequest) {
                LoadingButtonLabel(
                    isLoading: isRequesting,
                    tint: .white
                ) {
                    Label(String(localized: "action_allow"), systemImage: "bell.fill")
                        .font(.callout.weight(.semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isRequesting)
        @unknown default:
            EmptyView()
        }
    }
}
