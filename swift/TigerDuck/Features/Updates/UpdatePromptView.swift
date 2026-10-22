#if os(iOS)
import SwiftUI

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
