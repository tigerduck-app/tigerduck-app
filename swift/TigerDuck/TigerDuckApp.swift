import SwiftUI
import SwiftData

@main
struct TigerDuckApp: App {
    @State private var appState = AppState()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            SDCourse.self,
            SDAssignment.self,
            SDAnnouncement.self,
            SDCalendarEvent.self,
            SDUserProfile.self,
            SDWidgetConfig.self,
            SDTabConfig.self,
            SDHomeSectionConfig.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .tint(appState.accentColor)
                .preferredColorScheme(.dark)
        }
        .modelContainer(sharedModelContainer)
    }
}
