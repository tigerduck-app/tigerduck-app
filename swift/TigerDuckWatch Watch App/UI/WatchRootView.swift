import SwiftUI

struct WatchRootView: View {
    @EnvironmentObject private var store: ScheduleStore

    var body: some View {
        TabView {
            NavigationStack { NowNextView() }
            NavigationStack { TodayView() }
            NavigationStack { SettingsView() }
        }
        .tabViewStyle(.page)
        .modifier(WatchTheme(snapshot: store.snapshot))
        .onAppear {
            if store.shouldRequestSync() {
                store.requestSync()
            }
        }
    }
}
