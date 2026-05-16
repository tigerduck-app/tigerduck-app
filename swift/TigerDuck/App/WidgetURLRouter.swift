import Foundation

enum WidgetDestination: Equatable, Hashable, Sendable {
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
}
