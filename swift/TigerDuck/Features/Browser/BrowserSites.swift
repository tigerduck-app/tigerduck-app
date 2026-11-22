import Defaults
import Foundation

/// Each site's zoom and desktop-site choice, by host. They are the student's browsing, so
/// `BrowserData.reset()` forgets them with the browser's other data.
nonisolated struct BrowserSites: Equatable {
    var zoom: [String: Int] = [:]
    var desktop: Set<String> = []

    func zoom(for host: String) -> Int {
        PageZoom.browser.clamped(zoom[key(host)] ?? PageZoom.standard)
    }

    mutating func setZoom(_ percent: Int, for host: String) {
        zoom[key(host)] = percent == PageZoom.standard ? nil : percent
    }

    func isDesktop(_ host: String) -> Bool { desktop.contains(key(host)) }

    mutating func setDesktop(_ isDesktop: Bool, for host: String) {
        if isDesktop { desktop.insert(key(host)) } else { desktop.remove(key(host)) }
    }

    private func key(_ host: String) -> String { host.lowercased() }

    static var stored: BrowserSites {
        BrowserSites(zoom: Defaults[.browserZoom], desktop: Set(Defaults[.browserDesktopSites]))
    }

    static func change(for signIn: SignIn, _ body: (inout BrowserSites) -> Void) {
        guard signIn.isCurrent else { return }
        var sites = stored
        body(&sites)
        Defaults[.browserZoom, for: signIn] = sites.zoom
        Defaults[.browserDesktopSites, for: signIn] = sites.desktop.sorted()
    }

    static func forget() {
        Defaults.reset(.browserZoom, .browserDesktopSites)
    }
}

nonisolated struct BrowserSiteSetting: Equatable {
    var zoom = PageZoom.standard
    var isDesktop = false
}
