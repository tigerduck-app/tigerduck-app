import SwiftUI

struct WatchRootView: View {
    @EnvironmentObject private var store: ScheduleStore

    private enum Tab: Int, Hashable, CaseIterable {
        case libraryQR
        case nowNext
        case today
        case settings
    }

    @State private var selection: Tab = .nowNext
    @State private var dotsVisible = true
    @State private var idleHideTask: Task<Void, Never>?

    private static let idleHideDelay: Duration = .seconds(2)

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selection) {
                NavigationStack { LibraryQRView() }.tag(Tab.libraryQR)
                NavigationStack { NowNextView() }.tag(Tab.nowNext)
                NavigationStack { TodayView() }.tag(Tab.today)
                NavigationStack { SettingsView() }.tag(Tab.settings)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            dotsOverlay
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .modifier(WatchTheme(snapshot: store.snapshot))
        .onAppear {
            if store.shouldRequestSync() {
                store.requestSync()
            }
            scheduleHideAfterIdle()
        }
        .onChange(of: selection) {
            withAnimation(.easeInOut(duration: 0.2)) { dotsVisible = true }
            scheduleHideAfterIdle()
        }
    }

    private var dotsOverlay: some View {
        HStack(spacing: 5) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Circle()
                    .fill(Color.white.opacity(selection == tab ? 0.95 : 0.35))
                    .frame(width: 5, height: 5)
            }
        }
        .padding(.bottom, 6)
        .opacity(dotsVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.35), value: dotsVisible)
        .allowsHitTesting(false)
    }

    private func scheduleHideAfterIdle() {
        idleHideTask?.cancel()
        idleHideTask = Task { @MainActor in
            try? await Task.sleep(for: Self.idleHideDelay)
            guard !Task.isCancelled else { return }
            dotsVisible = false
        }
    }
}
