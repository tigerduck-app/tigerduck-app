import SwiftUI

extension View {
    func moodleAutoRefresh(
        every ttl: TimeInterval,
        fetchedAt: @escaping () -> Date?,
        refresh: @escaping () async -> Void
    ) -> some View {
        modifier(MoodleAutoRefreshModifier(ttl: ttl, fetchedAt: fetchedAt, refresh: refresh))
    }
}

private struct MoodleAutoRefreshModifier: ViewModifier {
    let ttl: TimeInterval
    let fetchedAt: () -> Date?
    let refresh: () async -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var timer: MoodleRefreshTimer?
    @State private var isOnScreen = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                isOnScreen = true
                update()
            }
            .onDisappear {
                isOnScreen = false
                update()
            }
            .onChange(of: scenePhase) { update() }
    }

    private func update() {
        let timer = timer ?? MoodleRefreshTimer(ttl: ttl)
        self.timer = timer
        guard isOnScreen, scenePhase == .active else {
            timer.stop()
            return
        }
        if !timer.isRunning { timer.start(fetchedAt: fetchedAt, refresh: refresh) }
    }
}
