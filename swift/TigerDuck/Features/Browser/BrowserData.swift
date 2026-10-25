import WebKit

/// The TigerDuck browser's website data: a store of its own, in memory only, so dropping it at a
/// sign-in or sign-out clears everything at once and nothing waits on a deletion that may never
/// report. A browser open across a reset closes, since it still shows the departing account.
@MainActor
@Observable
final class BrowserData {
    static let shared = BrowserData()

    private(set) var generation = 0
    @ObservationIgnored private var current: WKWebsiteDataStore?

    var store: WKWebsiteDataStore {
        if let current { return current }
        let store = WKWebsiteDataStore.nonPersistent()
        current = store
        return store
    }

    func reset() {
        generation += 1
        current?.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        current = nil
    }
}
