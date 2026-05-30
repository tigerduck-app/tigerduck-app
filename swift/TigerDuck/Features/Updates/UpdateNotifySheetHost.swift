#if os(iOS)
import SwiftUI

/// View-modifier wrapper that mounts the update-related sheets (Update
/// Prompt + What's New) on `MainTabView`. Applied at the same level as
/// `.flipToLibraryAttached()` and `.firstTriggerPromptHost()` so a stale
/// presentation cannot leak across tab swaps the way a per-tab
/// `.sheet(...)` would.
///
/// Both surfaces flow through a single `.sheet(item:)` driven by
/// ``UpdateNotifyCoordinator/activeNotifySheet``. Two stacked
/// `.sheet(item:)` modifiers on the same view race in SwiftUI — when
/// both items become non-nil in the same render cycle (a post-update
/// launch that's ALSO behind on App Store), only one ever presents and
/// the loser's `onDismiss` never fires, leaving its persisted seen-marker
/// un-advanced. The single-binding design dequeues them in priority
/// order instead: What's New presents first; dismissing it (any path)
/// acknowledges it and lets the update prompt take its place on the
/// next observation cycle.
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
            case .whatsNew(let entry):
                WhatsNewSheetView(entry: entry) {
                    coordinator.acknowledgeWhatsNew()
                }
                // Fraction picked to leave the icon + headline visible
                // above the first highlight on a 4.7" iPhone SE without
                // forcing scroll. The .large fallback accommodates
                // Dynamic Type's larger sizes via a drag-to-expand
                // gesture rather than capping the layout at the
                // smaller detent.
                .presentationDetents([.fraction(0.85), .large])
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
    case whatsNew(WhatsNewRepository.ResolvedWhatsNew)
    case update(UpdateNotifyCoordinator.PendingUpdate)

    var id: String {
        switch self {
        case .whatsNew(let entry): return "whatsNew:\(entry.version)"
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

extension WhatsNewRepository.ResolvedWhatsNew: Identifiable {
    /// `version` is the natural primary key for the registry — one
    /// entry per release.
    var id: String { version }
}
#endif
