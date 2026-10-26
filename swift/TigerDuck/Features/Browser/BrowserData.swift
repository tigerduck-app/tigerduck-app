import Defaults
import WebKit

/// The TigerDuck browser's website data: a store of its own, apart from the default one and kept
/// across launches, as Moodle gives one autologin key per six minutes. A sign-in and a sign-out
/// remove it; a browser open across that closes, since it still shows the departing account.
@MainActor
@Observable
final class BrowserData {
    static let shared = BrowserData()

    nonisolated static let storeID = UUID(uuidString: "6F1D5B0E-7A44-4C2B-9E3D-2B8C0A51D7F4")!

    private(set) var generation = 0
    @ObservationIgnored private var current: WKWebsiteDataStore?
    @ObservationIgnored private var opens = 0
    @ObservationIgnored private let loadState: () -> BrowserDataState
    @ObservationIgnored private let saveState: (BrowserDataState) -> Void
    @ObservationIgnored private let remove: () async -> Bool
    @ObservationIgnored private let clear: () async -> Void

    init(
        loadState: @escaping () -> BrowserDataState = { Defaults[.browserDataState] },
        saveState: @escaping (BrowserDataState) -> Void = { Defaults[.browserDataState] = $0 },
        remove: @escaping () async -> Bool = { await BrowserData.removeStore() },
        clear: @escaping () async -> Void = { await BrowserData.clearStore() }
    ) {
        self.loadState = loadState
        self.saveState = saveState
        self.remove = remove
        self.clear = clear
    }

    var store: WKWebsiteDataStore {
        if let current { return current }
        let store = WKWebsiteDataStore(forIdentifier: Self.storeID)
        current = store
        return store
    }

    /// Runs before a browser loads anything: what a reset could not remove goes first.
    func prepare() async {
        opens += 1
        let generation = generation
        if loadState() == .stale { await clear() }
        if self.generation == generation { saveState(.used) }
    }

    /// Returns the removal, which tests wait for.
    @discardableResult
    func reset() -> Task<Void, Never>? {
        generation += 1
        current = nil
        try? FileManager.default.removeItem(at: BrowserPage.downloadsRoot)
        Defaults.reset(.browserZoom, .browserDesktopSites)
        guard loadState() != .empty else { return nil }
        saveState(.stale)
        let opensAtStart = opens
        return Task {
            let removed = await remove()
            // A browser opened since has cleared the store itself and may be using it now.
            guard opens == opensAtStart else { return }
            if removed { saveState(.empty) } else { await clear() }
        }
    }

    /// WebKit refuses while a web view still has the store, as a browser that is closing does.
    private static func removeStore() async -> Bool {
        do {
            try await WKWebsiteDataStore.remove(forIdentifier: storeID)
            return true
        } catch {
            AppLogger.breadcrumb("browser store in use; clearing its data instead", category: "browser")
            return false
        }
    }

    private static func clearStore() async {
        await WKWebsiteDataStore(forIdentifier: storeID)
            .removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}
