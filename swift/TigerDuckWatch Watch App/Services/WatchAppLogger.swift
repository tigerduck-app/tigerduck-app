import Foundation
import os

nonisolated enum WatchAppLogger {
    static let app = Logger(subsystem: "org.ntust.app.TigerDuck.watchkitapp", category: "app")
    static let wc = Logger(subsystem: "org.ntust.app.TigerDuck.watchkitapp", category: "wc")
    static let widget = Logger(subsystem: "org.ntust.app.TigerDuck.watchkitapp", category: "widget")
}
