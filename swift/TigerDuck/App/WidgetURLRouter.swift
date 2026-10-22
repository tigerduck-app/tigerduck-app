import Foundation

enum WidgetDestination: nonisolated Equatable, nonisolated Hashable, Sendable {
    case library
    case classTable
}

enum WidgetURLRouter {
    static func route(_ url: URL) -> WidgetDestination? {
        guard url.scheme == "tigerduck", let host = url.host, !host.isEmpty else {
            return nil
        }
        switch host {
        case "library":    return .library
        case "classtable": return .classTable
        default:           return nil
        }
    }

    /// The "due soon" Live Activity's tap target. A Live Activity's `widgetURL` is a deep link
    /// into the app that owns it (Apple's `DynamicIsland.widgetURL(_:)` documentation), so the
    /// activity links to TigerDuck, and `TigerDuckApp` opens the assignment from the link.
    static func assignmentURL(id: String) -> URL? {
        var components = URLComponents()
        components.scheme = "tigerduck"
        components.host = "assignment"
        components.path = "/" + id
        return components.url
    }

    static func assignmentId(from url: URL) -> String? {
        guard url.scheme == "tigerduck", url.host == "assignment" else { return nil }
        let path = url.pathComponents.dropFirst()
        guard path.count == 1 else { return nil }
        return path.first
    }
}
