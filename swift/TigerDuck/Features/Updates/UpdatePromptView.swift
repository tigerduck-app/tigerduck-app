#if os(iOS)
import SwiftUI

/// Three-button "an update is ready" sheet. Owned by the
/// ``UpdateNotifyCoordinator`` flow — view receives the pending update
/// and dispatches the selected action through the closure passed in.
///
/// Why a custom sheet over `.alert`: the Update / Later / Skip choice
/// triad doesn't fit the iOS alert primary/secondary/destructive
/// rhetoric (Skip is destructive-ish but not OS-level "danger"), and a
/// sheet lets us include the latest version string with proper
/// hierarchy and a release-notes-style accent illustration. The
/// existing `FirstTriggerPromptCenter` pattern is the closest cousin in
/// the app but bakes in a per-feature "seen once" persistence model
/// that doesn't apply here — Later re-arms the same version after the
/// 24h throttle, only Skip suppresses it indefinitely.
struct UpdatePromptView: View {
    let pending: UpdateNotifyCoordinator.PendingUpdate
    let onAction: (UpdateNotifyCoordinator.UpdatePromptAction) -> Void

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Image(systemName: "arrow.down.app.fill")
                    .font(.system(size: 64, weight: .medium))
                    .foregroundStyle(.tint)
                    .padding(.top, 32)
                Text(String(localized: "update_available_title"))
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(String(
                    format: NSLocalizedString("update_available_message", comment: ""),
                    pending.latestVersion
                ))
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Button {
                    onAction(.updateNow)
                } label: {
                    Text(String(localized: "update_action_update_now"))
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    onAction(.later)
                } label: {
                    Text(String(localized: "update_action_later"))
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)

                // Skip is the destructive-tinted tail option so it reads
                // as "this version specifically — never again" without
                // looking like the primary action. Mirrors the iOS
                // Settings → App Updates "Skip this version" placement.
                Button(role: .destructive) {
                    onAction(.skipThisVersion)
                } label: {
                    Text(String(localized: "update_action_skip_version"))
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}
#endif
