#if os(iOS)
import SwiftUI

/// Mounts the update prompt and What's New sheets on `MainTabView`, at the same level as
/// `.flipToLibraryAttached()` and `.firstTriggerPromptHost()`, so a stale presentation cannot
/// leak across tab swaps as a per-tab `.sheet(...)` would.
///
/// Both go through one `.sheet(item:)` driven by ``UpdateNotifyCoordinator/activeNotifySheet``:
/// two on one view race when both items turn non-nil in one render (a post-update launch that is
/// also behind the App Store), and the loser never presents or runs `onDismiss`, so its seen-marker
/// never advances. What's New goes first; any dismissal acknowledges it, then the prompt shows.
private struct UpdateNotifySheetHost: ViewModifier {
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        let coordinator = appState.updateNotifyCoordinator
        return content.sheet(
            item: Binding<NotifySheet?>(
                get: { coordinator.activeNotifySheet },
                set: { newValue in
                    // Only `set(nil)` (dismissal) matters here; non-nil
                    // writes are driven by the coordinator's pending
                    // flags, not the sheet binding.
                    guard newValue == nil else { return }
                    coordinator.dismissActiveNotifySheet()
                }
            )
        ) { sheet in
            switch sheet {
            case .whatsNew(let presentation):
                WhatsNewFlowView(presentation: presentation) {
                    coordinator.acknowledgeWhatsNew()
                }
                .whatsNewSheetPresentation()
            case .update(let pending):
                UpdatePromptView(pending: pending) { action in
                    coordinator.handleUpdatePromptAction(action)
                }
                .presentationDetents([.fraction(0.7), .large])
            }
        }
    }
}

/// Discriminated union mapping the coordinator's two independent
/// pending flags to a single sheet item. The order in
/// ``UpdateNotifyCoordinator/activeNotifySheet`` decides priority when
/// both flags are set simultaneously.
enum NotifySheet: Identifiable, Equatable {
    case whatsNew(WhatsNewPresentation)
    case update(UpdateNotifyCoordinator.PendingUpdate)

    var id: String {
        switch self {
        case .whatsNew(let presentation): return "whatsNew:\(presentation.id)"
        case .update(let pending): return "update:\(pending.latestVersion)"
        }
    }
}

extension View {
    /// Apply the update-notify + What's New sheet host to a root view.
    /// Idempotent — safe to call multiple times, but should be applied
    /// exactly once near the app's root.
    func updateNotifySheetHost() -> some View {
        modifier(UpdateNotifySheetHost())
    }
}

extension UpdateNotifyCoordinator.PendingUpdate: Identifiable {
    /// `.sheet(item:)` needs Identifiable. The latest-version string is
    /// unique-per-presentation: re-arming with the same version requires
    /// the throttle to elapse AND a non-Skip dismiss path, by which
    /// point SwiftUI has cleared the previous sheet binding and reusing
    /// the same id is fine.
    var id: String { latestVersion }
}
#endif
