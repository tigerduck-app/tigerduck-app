import SwiftUI

/// Which window shows the pin-mismatch prompt. Every iPad window mounts the prompt at its root,
/// and only the one holding this shows it.
@MainActor
@Observable
final class TLSPinPromptOwner {
    static let shared = TLSPinPromptOwner()
    var holder: UUID?
}

/// Shows the queue's prompt over the window's root. Dismissing the sheet any other way than its
/// buttons, by a swipe or Escape, is a Cancel.
private struct TLSPinPromptHost: ViewModifier {
    let queue: TLSPinMismatchQueue
    let owner: TLSPinPromptOwner
    @State private var id = UUID()
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(AppState.self) private var appState: AppState?
    @State private var window = HostWindow()
    #endif

    private struct Turn: Equatable {
        let prompt: String?
        let holder: UUID?
        let isActive: Bool
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(
                get: { owner.holder == id ? queue.prompt : nil },
                set: { if $0 == nil { queue.cancel() } }
            )) { prompt in
                TLSPinPromptSheet(prompt: prompt, onCancel: queue.cancel, onContinue: queue.continue)
            }
            .task(id: Turn(prompt: queue.prompt?.id, holder: owner.holder, isActive: scenePhase == .active)) {
                await takeTurn()
            }
            .onDisappear { if owner.holder == id { owner.holder = nil } }
            #if os(iOS)
            .readsHostWindow(into: window)
            #endif
    }

    private func takeTurn() async {
        guard queue.prompt != nil else {
            if owner.holder == id { owner.holder = nil }
            return
        }
        while owner.holder == nil, scenePhase == .active, !Task.isCancelled {
            if !isShowingOtherPresentation {
                owner.holder = id
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// A sheet from the root would close one already up in the window, and with What's New about
    /// to show, one of the two would not present.
    private var isShowingOtherPresentation: Bool {
        #if os(iOS)
        window.window?.rootViewController?.presentedViewController != nil
            || appState?.updateNotifyCoordinator.activeNotifySheet != nil
        #else
        false
        #endif
    }
}

extension View {
    func tlsPinPrompt() -> some View {
        tlsPinPrompt(queue: .shared, owner: .shared)
    }

    func tlsPinPrompt(queue: TLSPinMismatchQueue, owner: TLSPinPromptOwner) -> some View {
        modifier(TLSPinPromptHost(queue: queue, owner: owner))
    }
}
