import SwiftUI
import SwiftData

enum BrowserPreference: String, CaseIterable {
    case system
    case inApp
}

@Observable
final class AppState {
    var hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

    let authService = AuthService()
    let sessionManager = NTUSTSessionManager.shared

    var isNTUSTLoggedIn: Bool { authService.isNTUSTAuthenticated }
    var isMoodleLinked: Bool { authService.isNTUSTAuthenticated }
    var isLibraryLoggedIn: Bool { LibraryService.isTokenValid }

    // MARK: - Theme

    /// Accent color hex stored as Int (default system blue 0x007AFF)
    var accentColorHex: Int = UserDefaults.standard.object(forKey: "accentColorHex") as? Int ?? 0x007AFF {
        didSet { UserDefaults.standard.set(accentColorHex, forKey: "accentColorHex") }
    }

    var accentColor: Color {
        Color(hex: UInt(accentColorHex))
    }

    static let themeColors: [(name: String, hex: Int)] = [
        ("藍", 0x007AFF),
        ("紫", 0xAF52DE),
        ("粉", 0xFF2D55),
        ("紅", 0xFF3B30),
        ("橘", 0xFF9500),
        ("綠", 0x34C759),
        ("青", 0x5AC8FA),
        ("靛", 0x5856D6),
    ]

    // MARK: - Settings

    /// Whether to persist announcement filter selection across sessions
    var rememberAnnouncementFilter: Bool = UserDefaults.standard.bool(forKey: "rememberAnnouncementFilter") {
        didSet { UserDefaults.standard.set(rememberAnnouncementFilter, forKey: "rememberAnnouncementFilter") }
    }

    /// Saved announcement filter departments (JSON array)
    var savedAnnouncementDepartments: Set<String> {
        get {
            guard let data = UserDefaults.standard.data(forKey: "savedAnnouncementDepartments"),
                  let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return Set(arr)
        }
        set {
            if let data = try? JSONEncoder().encode(Array(newValue)) {
                UserDefaults.standard.set(data, forKey: "savedAnnouncementDepartments")
            }
        }
    }

    /// Browser preference for opening links
    var browserPreference: BrowserPreference = {
        if let raw = UserDefaults.standard.string(forKey: "browserPreference"),
           let pref = BrowserPreference(rawValue: raw) {
            return pref
        }
        return .system
    }() {
        didSet { UserDefaults.standard.set(browserPreference.rawValue, forKey: "browserPreference") }
    }

    /// Assignment time display: true = absolute (2026/3/24 23:59:00), false = relative (5 天後)
    var showAbsoluteAssignmentTime: Bool = UserDefaults.standard.bool(forKey: "showAbsoluteAssignmentTime") {
        didSet { UserDefaults.standard.set(showAbsoluteAssignmentTime, forKey: "showAbsoluteAssignmentTime") }
    }

    // MARK: - Tab Configuration

    var configuredTabs: [AppFeature] = {
        if let data = UserDefaults.standard.data(forKey: "configuredTabs"),
           let rawValues = try? JSONDecoder().decode([String].self, from: data) {
            let features = rawValues.compactMap { AppFeature(rawValue: $0) }
            return features.isEmpty ? AppFeature.defaultTabs : features
        }
        return AppFeature.defaultTabs
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(configuredTabs.map(\.rawValue)) {
                UserDefaults.standard.set(data, forKey: "configuredTabs")
            }
        }
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
    }

    /// Background sync all data on app launch
    func backgroundSync() {
        guard hasCompletedOnboarding else { return }
        Task {
            sessionManager.loadingState = .loading

            async let courses = KMPServiceBridge.fetchCourses(authService: authService)
            async let assignments = KMPServiceBridge.fetchAssignments(authService: authService)
            async let schoolEvents = CalendarService.fetchAndParseICS()

            // Await all — results are cached by their respective services
            let _ = await courses
            let _ = await assignments
            let fetchedSchoolEvents = await schoolEvents

            // Merge school events into calendar cache
            if !fetchedSchoolEvents.isEmpty {
                var cached = DataCache.shared.loadCalendarEvents()
                cached.removeAll { $0.source == .school }
                cached.append(contentsOf: fetchedSchoolEvents)
                DataCache.shared.saveCalendarEvents(cached)
            }

            await MainActor.run {
                sessionManager.loadingState = .loaded
            }
        }
    }

    /// Open a URL using the user's browser preference
    func openURL(_ url: URL) {
        UIApplication.shared.open(url)
    }
}
