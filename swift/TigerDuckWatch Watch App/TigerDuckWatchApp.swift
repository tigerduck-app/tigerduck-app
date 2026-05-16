import SwiftUI

@main
struct TigerDuckWatchApp: App {
    @StateObject private var store: ScheduleStore

    init() {
        let store = ScheduleStore()
        store.activate()
        _store = StateObject(wrappedValue: store)
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(store)
        }
    }
}
