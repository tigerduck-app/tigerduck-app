import SwiftUI

struct WatchRootView: View {
    @EnvironmentObject private var store: ScheduleStore

    private enum Tab: Int, Hashable {
        case libraryQR
        case nowNext
        case today
        case settings
    }

    @State private var selection: Tab = .nowNext

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { LibraryQRView() }.tag(Tab.libraryQR)
            NavigationStack { NowNextView() }.tag(Tab.nowNext)
            NavigationStack { TodayView() }.tag(Tab.today)
            NavigationStack { SettingsView() }.tag(Tab.settings)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .modifier(WatchTheme(snapshot: store.snapshot))
        .onAppear {
            if store.shouldRequestSync() {
                store.requestSync()
            }
        }
    }
}
