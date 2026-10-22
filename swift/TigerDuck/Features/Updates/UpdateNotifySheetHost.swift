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
    func updateNotifySheetHost() -> some View {
        modifier(UpdateNotifySheetHost())
    }
}

extension UpdateNotifyCoordinator.PendingUpdate: Identifiable {
    var id: String { latestVersion }
}
#endif
