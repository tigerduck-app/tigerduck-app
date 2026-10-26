import Defaults
import Foundation

/// Page zoom in the TigerDuck browser, as a percentage, in Safari's steps.
nonisolated enum BrowserZoom {
    static let steps = [50, 75, 85, 100, 115, 125, 150, 175, 200]
    static let standard = 100

    /// The next step up, or nil at the largest; a value between steps goes to the one above it.
    static func larger(than percent: Int) -> Int? { steps.first { $0 > percent } }

    static func smaller(than percent: Int) -> Int? { steps.last { $0 < percent } }
}

/// Each site's zoom and desktop-site choice, by host. They are the student's browsing, so
/// `BrowserData.reset()` forgets them with the browser's other data.
nonisolated struct BrowserSites: Equatable {
    var zoom: [String: Int] = [:]
    var desktop: Set<String> = []

    func zoom(for host: String) -> Int {
        min(max(zoom[key(host)] ?? BrowserZoom.standard, BrowserZoom.steps[0]), BrowserZoom.steps[BrowserZoom.steps.count - 1])
    }

    mutating func setZoom(_ percent: Int, for host: String) {
        zoom[key(host)] = percent == BrowserZoom.standard ? nil : percent
    }

    func isDesktop(_ host: String) -> Bool { desktop.contains(key(host)) }

    mutating func setDesktop(_ isDesktop: Bool, for host: String) {
        if isDesktop { desktop.insert(key(host)) } else { desktop.remove(key(host)) }
    }

    private func key(_ host: String) -> String { host.lowercased() }

    static var stored: BrowserSites {
        get { BrowserSites(zoom: Defaults[.browserZoom], desktop: Set(Defaults[.browserDesktopSites])) }
        set {
            Defaults[.browserZoom] = newValue.zoom
            Defaults[.browserDesktopSites] = newValue.desktop.sorted()
        }
    }
}
