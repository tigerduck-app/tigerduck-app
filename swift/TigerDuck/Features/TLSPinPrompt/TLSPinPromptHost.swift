import SwiftUI

/// Which window shows the pin-mismatch prompt. Every iPad window mounts the prompt at its root,
/// and only the one holding this shows it.
@MainActor
@Observable
final class TLSPinPromptOwner {
    static let shared = TLSPinPromptOwner()
    var holder: UUID?
}

extension TLSPinMismatchQueue {
    /// Answers only the prompt the user saw, so a late tap or a closing sheet never answers a
    /// newer one.
    func answer(_ shown: TLSPinMismatch, continues: Bool) {
        guard prompt == shown else { return }
        if continues { self.continue() } else { cancel() }
    }
}

/// Shows the queue's prompt over the window's root. Dismissing the sheet any other way than its
/// buttons, by a swipe or Escape, is a Cancel.
private struct TLSPinPromptHost: ViewModifier {
    let queue: TLSPinMismatchQueue
    let owner: TLSPinPromptOwner
    @State private var id = UUID()
    @State private var presentation = Presentation()
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(AppState.self) private var appState: AppState?
    @State private var window = HostWindow()
    #endif

    /// The sheet's own item, set only once the window is free, so the sheet never shows a prompt
    /// the queue has replaced and closing it can tell a swipe from the queue taking it back.
    @MainActor
    @Observable
    final class Presentation {
        var prompt: TLSPinMismatch?
        @ObservationIgnored var requestedAt: ContinuousClock.Instant?
        @ObservationIgnored var isOnScreen = false
        @ObservationIgnored var isGone = false
    }

    private struct Turn: Equatable {
        let prompt: String?
        let holder: UUID?
        let phase: ScenePhase
    }

    /// SwiftUI does not present over another presentation, and may or may not try again later.
    private static let presentTimeout: Duration = .seconds(3)

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(
                get: { presentation.prompt },
                set: { if $0 == nil { closedOutsideButtons() } }
            )) { prompt in
                TLSPinPromptSheet(
                    prompt: prompt,
                    onCancel: { reply(prompt, continues: false) },
                    onContinue: { reply(prompt, continues: true) }
                )
                .id(prompt.id)
                .onAppear { presentation.isOnScreen = true }
                .onDisappear { presentation.isOnScreen = false }
            }
            .task(id: Turn(prompt: queue.prompt?.id, holder: owner.holder, phase: scenePhase)) {
                await takeTurn()
            }
            .onAppear { presentation.isGone = false }
            .onDisappear {
                presentation.isGone = true
                presentation.prompt = nil
                if owner.holder == id { owner.holder = nil }
            }
            #if os(iOS)
            .readsHostWindow(into: window)
            #endif
    }

    private func reply(_ prompt: TLSPinMismatch, continues: Bool) {
        guard queue.prompt == prompt else { return }
        presentation.prompt = nil
        queue.answer(prompt, continues: continues)
    }

    /// A swipe down. A window closing with the sheet up sets the item to nil as well, before its
    /// `onDisappear`, so the Cancel waits a turn and is dropped if the host went away.
    private func closedOutsideButtons() {
        guard let closed = presentation.prompt else { return }
        presentation.prompt = nil
        presentation.requestedAt = nil
        Task { [presentation, queue] in
            guard !presentation.isGone else { return }
            queue.answer(closed, continues: false)
        }
    }

    /// Restarts whenever the prompt, the holder or the scene phase changes; each run picks up
    /// where an earlier one left off.
    private func takeTurn() async {
        while !Task.isCancelled {
            guard let prompt = queue.prompt else {
                presentation.prompt = nil
                if owner.holder == id { owner.holder = nil }
                return
            }
            if owner.holder == nil {
                if scenePhase == .active, !isShowingOtherPresentation { owner.holder = id }
            } else if owner.holder != id {
                presentation.prompt = nil
                return
            } else if scenePhase == .background {
                // Another iPad window can still be active, and the queue keeps the prompt for it.
                presentation.prompt = nil
                owner.holder = nil
                return
            } else if presentation.prompt == nil, isShowingOtherPresentation {
                owner.holder = nil
            } else {
                await show(prompt)
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Presents the prompt, then gives the window back if the sheet has not come up in time.
    private func show(_ prompt: TLSPinMismatch) async {
        if presentation.prompt != prompt {
            presentation.prompt = prompt
            presentation.requestedAt = .now
        }
        guard let requestedAt = presentation.requestedAt else { return }
        while !presentation.isOnScreen, ContinuousClock.now < requestedAt + Self.presentTimeout {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return }
        }
        presentation.requestedAt = nil
        if !presentation.isOnScreen {
            presentation.prompt = nil
            owner.holder = nil
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
