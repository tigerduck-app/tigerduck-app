import SwiftUI

struct OnboardingPrivacyPage: View {
    @Binding var agreedPrivacy: Bool
    @Binding var agreedDeletion: Bool
    let isCurrent: Bool
    let onNext: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasAgreedToTerms: Bool { agreedPrivacy && agreedDeletion }

    var body: some View {
        OnboardingPageView(
            icon: "lock.shield.fill",
            title: String(localized: "onboarding_privacy_title"),
            subtitle: String(localized: "onboarding_privacy_subtitle"),
            accentColor: .blue,
            iconAnimation: .layerFlash,
            justifiesSubtitle: true,
            content: {
                Grid(alignment: .leading, horizontalSpacing: TigerDuckTheme.Spacing.md, verticalSpacing: TigerDuckTheme.Spacing.md) {
                    privacyCheckboxRow(
                        isOn: $agreedPrivacy,
                        label: String(localized: "onboarding_privacy_policy_label"),
                        destination: AppURLs.privacyPolicy
                    )
                    privacyCheckboxRow(
                        isOn: $agreedDeletion,
                        label: String(localized: "onboarding_privacy_delete_account_label"),
                        destination: AppURLs.deleteAccount
                    )
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            },
            actions: {
                VStack(spacing: TigerDuckTheme.Spacing.sm) {
                    Text(String(localized: "onboarding_privacy_continue_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .opacity(hasAgreedToTerms ? 0 : 1)

                    Button(String(localized: "action_next"), action: onNext)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!hasAgreedToTerms)
                }
            }
        )
        .background(
            PagingScrollLock(isLocked: isCurrent && !hasAgreedToTerms)
                .allowsHitTesting(false)
        )
    }

    private func privacyCheckboxRow(
        isOn: Binding<Bool>, label: String, destination: URL
    ) -> some View {
        GridRow {
            Button {
                isOn.wrappedValue.toggle()
            } label: {
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isOn.wrappedValue ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.textSecondary))
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.selection, trigger: isOn.wrappedValue)
            .accessibilityRepresentation {
                Toggle(label, isOn: isOn)
            }

            Link(label, destination: destination)
                .font(.callout)
        }
    }
}
