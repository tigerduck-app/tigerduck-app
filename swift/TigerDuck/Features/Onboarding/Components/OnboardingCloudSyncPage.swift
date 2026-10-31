import SwiftUI

/// The onboarding page that lists what TigerSync shares and lets the user turn it off.
struct OnboardingCloudSyncPage: View {
    @Binding var syncEnabled: Bool
    let onNext: () -> Void

    var body: some View {
        OnboardingPageView(
            icon: "arrow.triangle.2.circlepath.icloud.fill",
            title: String(localized: "onboarding_sync_title"),
            subtitle: String(localized: "onboarding_sync_subtitle"),
            accentColor: .cyan,
            content: {
                VStack(spacing: TigerDuckTheme.Spacing.md) {
                    cloudSyncInfoRows

                    Toggle(isOn: $syncEnabled) {
                        Text(String(localized: "onboarding_sync_toggle_label"))
                            .font(.callout.weight(.semibold))
                    }
                    .toggleStyle(.switch)
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)

                    if !syncEnabled {
                        Label(
                            String(localized: "onboarding_sync_disabled_note"),
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                    }

                    VStack(spacing: TigerDuckTheme.Spacing.sm) {
                        Link(destination: AppURLs.learnMoreTigerSync) {
                            Label(String(localized: "settings_learn_more_backend"), systemImage: "server.rack")
                                .font(.caption)
                        }
                        Link(destination: AppURLs.privacyPolicy) {
                            Label(String(localized: "onboarding_privacy_policy_label"), systemImage: "hand.raised.fill")
                                .font(.caption)
                        }
                        Link(destination: AppURLs.deleteAccount) {
                            Label(String(localized: "onboarding_privacy_delete_account_label"), systemImage: "trash")
                                .font(.caption)
                        }
                    }
                    .padding(.top, TigerDuckTheme.Spacing.sm)
                }
            },
            actions: {
                Button(String(localized: "action_next"), action: onNext)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        )
    }

    @ViewBuilder
    private var cloudSyncInfoRows: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            cloudSyncInfoRow(
                icon: "checkmark.circle.fill",
                color: .green,
                text: String(localized: "onboarding_sync_shared_student_id")
            )
            cloudSyncInfoRow(
                icon: "checkmark.circle.fill",
                color: .green,
                text: String(localized: "onboarding_sync_shared_moodle_token")
            )
            cloudSyncInfoRow(
                icon: "checkmark.circle.fill",
                color: .green,
                text: String(localized: "onboarding_sync_shared_device_id")
            )
            cloudSyncInfoRow(
                icon: "checkmark.circle.fill",
                color: .green,
                text: String(localized: "onboarding_sync_shared_courses")
            )
            cloudSyncInfoRow(
                icon: "checkmark.circle.fill",
                color: .green,
                text: String(localized: "onboarding_sync_shared_assignments")
            )
            cloudSyncInfoRow(
                icon: "xmark.circle.fill",
                color: .red,
                text: String(localized: "onboarding_sync_not_shared_password")
            )
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    private func cloudSyncInfoRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: TigerDuckTheme.Spacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.callout)
            Text(text)
                .font(.callout)
                .foregroundStyle(Color.textSecondary)
        }
    }
}
