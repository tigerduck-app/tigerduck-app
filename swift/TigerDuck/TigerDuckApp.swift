import SwiftUI
import SwiftData

@main
struct TigerDuckApp: App {
    @State private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            SDCourse.self,
            SDAssignment.self,
            SDAnnouncement.self,
            SDCalendarEvent.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            // Schema incompatible with existing store (e.g. upgrade from early version).
            // Delete the old store and retry.
            let storeURL = modelConfiguration.url
            let relatedFiles = [
                storeURL,
                storeURL.appendingPathExtension("wal"),
                storeURL.appendingPathExtension("shm"),
            ]
            for file in relatedFiles {
                try? FileManager.default.removeItem(at: file)
            }
            do {
                return try ModelContainer(for: schema, configurations: [modelConfiguration])
            } catch {
                fatalError("Could not create ModelContainer after reset: \(error)")
            }
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .tint(appState.accentColor)
                .preferredColorScheme(.dark)
                .onAppear {
                    appState.backgroundSync()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task {
                            await appState.refreshLiveActivity()
                            await appState.rescheduleReminders()
                        }
                    }
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
